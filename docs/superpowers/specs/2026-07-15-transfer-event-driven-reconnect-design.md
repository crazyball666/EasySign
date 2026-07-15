# Transfer Event-Driven Auto-Reconnect Design

## Context

EasySign already persists paired peers by device ID and TLS certificate fingerprint. A reconnect between paired devices therefore does not need a six-digit pairing code. The current reconnect implementation nevertheless wedges after the first failed fast retry: `scheduleReconnect()` clears `wasConnected`, the failed attempt cannot schedule the next retry, and `maybeAutoReconnect()` rejects attempts 1 and 2. Wake handling can also return while the connection still has a stale `.connected` or `.connecting` state, before repairing the listener and Bonjour discovery.

The desired behavior is automatic recovery after sleep or a network interruption, without indefinite background polling and without requiring the user to click Retry.

## Goals

- Reconnect paired devices automatically after system wake, network restoration, or matching-peer rediscovery.
- Use event-driven recovery rather than an unbounded periodic retry loop.
- Tolerate the short interval in which the local network is reported available but Bonjour or the peer listener is not ready yet.
- Preserve deterministic one-way dial arbitration: only the device with the smaller device ID initiates a reconnect.
- Keep user-initiated Disconnect authoritative.
- Reconnect without reading, rotating, or transmitting a pairing code.
- Prevent stale timeout or connection callbacks from changing the state of a newer connection.

## Non-Goals

- Automatically reconnecting after the EasySign process is terminated and relaunched. `lastConnectedPeer` remains an app-lifetime value.
- Changing the pairing protocol, persisted peer format, TLS identity format, or certificate fingerprint trust model.
- Maintaining an infinite retry timer while the peer or network remains unavailable.
- Redesigning the Transfer UI.

## Considered Approaches

### 1. Pure one-shot event recovery

Wake, path restoration, or peer discovery causes one reconnect attempt. This is simple, but it is vulnerable to normal recovery races: `NWPath` can become satisfied before Wi-Fi multicast DNS or the peer listener is ready.

### 2. Event-driven recovery with a bounded settling window — selected

A recovery event starts a finite cycle with delays `[0, 2, 5, 10]` seconds. Attempts run only while the path is satisfied, the matching paired peer remains valid, and this device wins dial arbitration. After four unsuccessful attempts, all timers stop and the service waits for a new wake, path, discovery, or inbound-connection event.

This handles network-settling races without creating indefinite background activity.

### 3. Infinite exponential retry

Retry forever with a capped interval. This eventually reconnects without another event, but creates unnecessary wakeups, connection noise, and logs when a peer is intentionally offline. It is not selected.

## Architecture

### `TransferReconnectCoordinator`

Add a small pure-logic coordinator under `Core/Transfer`. It owns recovery-cycle state and decisions, but does not import AppKit, create `NWConnection` objects, or schedule GCD work itself.

Inputs:

- unexpected active-connection drop;
- system wake or app activation;
- path transition from non-satisfied to satisfied;
- matching Bonjour peer appearance or endpoint change;
- reconnect attempt success or failure;
- inbound connection success;
- user Disconnect/Stop.

State:

- last connected `PeerRef`;
- whether automatic recovery is permitted;
- recovery generation;
- current attempt index in `[0, 2, 5, 10]`;
- whether an attempt or delayed attempt is active;
- whether the service is waiting for a new external event.

Outputs/actions:

- repair reachability infrastructure;
- refresh discovery;
- reassert Bonjour advertising;
- dial now;
- schedule the next bounded delay;
- cancel the current recovery generation;
- wait for another external event.

`TransferService` remains responsible for executing these actions and mapping them to published UI state.

### Service-lifetime network path monitor

Add a Core-level network path observer owned by `TransferService`. The existing `TransferNetworkPathObserver` in `Features/Transfer` is display-only and stops when the view disappears, so it cannot drive recovery.

Only a transition into `.satisfied` is a reconnect event. Repeated satisfied updates for the same effective path must not continually restart a cycle. An unsatisfied transition cancels pending dial timers but retains the last peer as the recovery target.

### Listener and discovery repair

Wake and path-restored handling must repair infrastructure before consulting `connectionState`:

1. ask `TransferServer` to rebuild a terminal listener;
2. reassert Bonjour advertising when stealth mode is off;
3. restart `PeerDiscovery` with a new browser generation;
4. ignore callbacks from superseded browser generations;
5. request recovery if the old active connection has already terminated.

Infrastructure repair is safe while an old connection still reports `.connected`: the busy connection prevents a dial, but listener/discovery recovery is not skipped.

`PeerDiscovery` should report terminal browser failure or restart itself so that a failed browser cannot remain silent indefinitely.

## Reconnect Flow

### Unexpected disconnect

1. Clear the dropped `activeConn`, transfer progress, connection timeout, and per-connection handlers exactly once.
2. Preserve `lastConnectedPeer` and mark automatic recovery permitted.
3. If the network path is unavailable, publish a waiting/failure message and do not schedule a dial.
4. If the path is satisfied, repair advertising/discovery and evaluate dial arbitration.
5. If this device has the smaller device ID and the matching paired peer is discoverable, start the bounded recovery cycle.
6. If this device has the larger device ID, never dial; remain reachable and wait for the peer's inbound connection.

The original inbound/outbound direction does not decide who reconnects. Device-ID arbitration is the only dial ownership rule.

### Wake or path restoration

1. Increment the infrastructure/discovery generation as needed and repair listener, advertising, and browser state.
2. Do not rely on the old `connectionState`, because Network.framework may deliver its terminal callback after the wake notification.
3. If the old connection later proves healthy, no dial occurs.
4. If it terminates, the current recovery event and refreshed discovery results can start a bounded cycle immediately.

### Matching peer discovery

- Match both device ID and certificate fingerprint.
- Resolve the current Bonjour endpoint on every attempt rather than closing over a stale `DiscoveredPeer` value.
- A peer appearance or endpoint change after attempts were exhausted is a new recovery event and starts a fresh bounded cycle.
- Duplicate callbacks for an unchanged peer while a cycle is already dialing or waiting do not reset the attempt counter.

### Bounded attempt cycle

- Attempt 1 is immediate.
- After failure, attempts 2–4 wait 2, 5, and 10 seconds respectively.
- Before every delayed attempt, validate the recovery generation, path availability, pairing record, peer fingerprint, arbitration result, and lack of an active connection.
- Success clears the cycle and returns to connected state.
- Exhaustion cancels all retry work and publishes that EasySign is waiting for the next network/device recovery event.
- A fresh qualifying event resets the attempt index and may start a new cycle.

## Manual IP Compatibility

Bonjour-discovered peers use a freshly resolved endpoint for each attempt. For an existing manual IP connection, retain the saved host/port as a fallback on path restoration. If the same paired peer subsequently appears through Bonjour, prefer the current Bonjour endpoint because a rebuilt listener may have a different port.

## User-Initiated Disconnect and Stop

`disconnect()` and `stop()` must:

- clear `lastConnectedPeer` as today;
- disable automatic recovery;
- increment the recovery generation;
- cancel pending retry work;
- preserve the `.bye` behavior so the peer also clears its auto-reconnect target.

No later wake, path, discovery, timeout, or stale connection callback may restart that session.

## Pairing and Trust

Every automatic attempt passes `pairingCode: nil`. After TLS reaches ready, the connection is accepted only when the leaf certificate fingerprint exists in `PairedPeerStore` and matches the recorded peer. Pairing-code rotation after a successful first pairing is unchanged and irrelevant to reconnect.

## Timeout and Callback Safety

Each connection attempt receives both a connection identity and recovery generation. Timeout and terminal callbacks must verify both before mutating shared state. All terminal paths converge on one idempotent attempt-completion method, preventing `.failed` plus `.cancelled` from consuming two attempts or an old 12-second timeout from cancelling a replacement connection.

## UI Behavior

- During a bounded attempt, the existing connecting/reconnecting presentation may be used.
- When the network is unavailable or the bounded cycle is exhausted, show a message such as “连接中断，等待网络或设备恢复后自动重连”.
- The manual Retry action may remain as an optional override, but normal sleep/network recovery must not require it.
- A completed attempt must never leave the UI indefinitely in `.connecting`.

## Testing

Extracting the coordinator permits standalone `swiftc @main` tests without real sleep or two physical Macs.

Required regression cases:

1. An unexpected drop followed by one failed attempt schedules attempt 2 instead of wedging at attempt index 1.
2. The bounded sequence is exactly 0/2/5/10 seconds and stops after four failures.
3. A new path-restored or changed-peer event restarts an exhausted cycle.
4. Duplicate unchanged discovery events do not restart an active cycle.
5. An unsatisfied path cancels timers and a later satisfied transition starts recovery.
6. The smaller device ID dials; the larger ID only advertises/waits, regardless of the original connection direction.
7. Wake while the UI state is still connected repairs listener/discovery without immediately creating a competing connection.
8. User Disconnect cancels a pending generation and all later stale callbacks are ignored.
9. A timeout from an old connection cannot cancel or fail a replacement connection.
10. Every automatic dial uses the codeless paired-fingerprint path.

Existing TLS loopback, disconnect-detection, Bonjour endpoint, pairing-repair, and auto-reconnect decision tests remain required regression coverage.

## Acceptance Criteria

- With A and B paired and connected, sleep or lock either Mac until its network drops. After wake and network restoration, the pair reconnects without clicking Retry or entering a code.
- Disabling and re-enabling Wi-Fi on either Mac produces the same automatic recovery.
- Leaving a peer offline causes no continuing retry timer after the bounded recovery window.
- Bringing the peer back or restoring the network generates a new event and reconnects automatically.
- User-initiated Disconnect stays disconnected across wake, path, and discovery events.
- At most one side actively dials during recovery, and neither side remains indefinitely in Connecting.
