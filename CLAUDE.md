# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

EasySign is a macOS SwiftUI app — a developer toolbox that began as an iOS IPA re-signer and now hosts four tools behind a sidebar: **Resign**, **QRCode**, **Devices** (browse connected-iOS-device files over MobileDevice.framework), and **Transfer** (LAN peer-to-peer sync). Two auxiliary app-extension targets, `EasySignQuickLook` and `EasySignThumbnail`, provide Finder preview/thumbnails for IPA & mobileprovision files.

> **Deep architecture reference: [`docs/architecture.md`](docs/architecture.md)** — layering rules, the Tool/ServiceHub DI contract, per-subsystem design, appex code-sharing, and known tech debt. Resign-backend detail: [`docs/zsign-backend.md`](docs/zsign-backend.md). This file is the quick orientation.

## Build Commands

```bash
# Raw .xcodeproj — no CocoaPods, no xcodegen. CryptoSwift comes via Swift Package Manager.
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Release build
```

The project uses Xcode 16 `PBXFileSystemSynchronizedRootGroup`: new `.swift` files under `EasySign/` auto-join the target — no `project.pbxproj` edit needed. Deployment target is macOS 14.0.

## Architecture

Three layers, dependencies flow downward only: **App (shell) → Features (per-tool views) → Core (engines/services, no UI)**. Tools plug in via the `Tool` protocol, register in `ToolRegistry.allTools`, and get shared services through the `ServiceHub` composition root (built once in `ServiceHub.live()`). See `docs/architecture.md` for the full picture; the essentials:

- **`App/`** — entry (`EasySignApp.swift`), `RootView`/`SidebarView` (resizable multi-tool shell), `SettingsView`, menu-bar residency (`TransferMenuBar`), update UI.
- **`Features/{Resign,QRCode,Devices,Transfer}/`** — each tool's SwiftUI views + a small `*Tool.swift` conforming to `Tool`.
- **`Core/`** — `Toolkit/` (Tool/ToolRegistry/ServiceHub/ServiceKey DI), `Resigning/` (signing core), `Devices/` (self-implemented AFC/HouseArrest/InstallationProxy over MobileDevice.framework), `Transfer/`, `QR/`, `Update/`, `Storage/`, `Logging/`, `UI/`.

### Resign core (`Core/Resigning/`)
Signing logic lives in `Core/Resigning/` (the old `ResignService/` is deleted). `Model/` holds the data + orchestration types (`IPA`, `AppBundle`, `BaseBundle`, `AppexBundle`, `ResignTask`, `ResignTaskInfo`, `PKCS12`, `MobileProvision`, `SecCerticate`, plus the newer zsign layer: `EntitlementReconciler`, `MachOCodeSignatureInspector`, `MachOExecutableScanner`, `ZSignProfileContext`, `ResignOutputPublisher`). `Utils/` has `TaskCenter` (shell exec via `TaskCenter.execute`) + `PathManager`; `Ext/` has Data/Date/NSError; `ZSign/` bridges the embedded C++ zsign (`ZSignBridge`).

Two backends selected by `ResignTaskInfo.backend` (a `switch` in `ResignTask.start()`, no protocol yet):
- `.zsign` (default) — in-process embedded zsign; entitlements reconciled by `EntitlementReconciler`, output verified (`verifyZSignCandidate`) and published transactionally (`ResignOutputPublisher`).
- `.apple` (legacy) — `codesign` + xcarchive template + `xcodebuild -exportArchive`.

Appex plugins are signed with the **main app certificate** (separate appex certs were removed). Export types (`ResignExportType`): app-store, development, ad-hoc, enterprise, validation — on the zsign path they only shape entitlements. Optional dylib injection adds a `@executable_path/<name>` load command via embedded zsign.

### Resources & vendored deps
- `EasySign/Resources/resign_template/` — xcarchive template for the Apple path's `xcodebuild -exportArchive`.
- `EasySign/Vendor/OpenSSL/` — bundled OpenSSL.xcframework (zsign crypto).
- `EasySign/Vendor/ZSign/` — embedded zsign source (signing + Mach-O dylib injection). Its bridge/injector live in `Core/Resigning/ZSign/` — **not** a duplicate of the upstream lib.
- CryptoSwift via Swift Package Manager (no CocoaPods).

### Transfer / 互联 (EasySign/Core/Transfer/)
LAN peer-to-peer sync (clipboard text/images + files) between two EasySign instances. Independent of the resign pipeline. `TransferService` is the ObservableObject facade (lives in `ServiceHub`, App lifetime), publishing state for the UI in `Features/Transfer/` and `App/TransferMenuBar.swift`.

**Transport & trust:**
- Discovery: Bonjour `_easysign-transfer._tcp` (`PeerDiscovery`), TXT carries deviceId/name/cert-fingerprint.
- Connection: WebSocket-over-TLS via Network.framework (`TransferServer` listens, `TransferClient` dials, `TransferConnection` wraps an `NWConnection`). Each connection reads the peer's leaf-cert fingerprint from its own TLS metadata.
- Pairing (first time): 6-digit code → symmetric HMAC-SHA256 proof (`PairingManager` / `PairingCrypto`). On success the peer is persisted to `PairedPeerStore` (UserDefaults JSON) and the code rotates.
- Reconnect (already paired): **codeless** — TLS certificate-fingerprint pinning against `PairedPeerStore`; the pairing code is never involved. `pendingPairingCode` is in-memory only (regenerated each launch / after each pairing); it is irrelevant to reconnection.

**Reconnection invariants (subtle — read before touching `TransferReconnectCoordinator` / `requestAutomaticRecovery`):**
- **Event-driven finite window:** an unexpected bound-connection drop, wake/app activation, an initial/restored usable network path, the matching Bonjour peer appearing/changing, or a bound session learning/changing its trusted endpoint can start recovery. One generation attempts at **0/2/5/10 seconds**; after four failures it enters `waitingForEvent` with no timer. A later valid recovery event starts a new generation. Repeated events for the same endpoint do not reset an active cycle.
- **Automatic target + one-way dial arbitration:** only the device with the **smaller deviceId** may dial; the larger device repairs its listener/advertisement and waits for inbound. A dial also requires a satisfied network path and a still-paired `PeerRef` (deviceId + fingerprint). The current matching Bonjour endpoint is preferred; when Bonjour is absent, the App may use an App-lifetime trusted fallback learned from a bound TLS connection's observed remote IP plus the peer's `reconnectHint` listener port. This learned address changes only *where* to dial and never bypasses arbitration or TLS trust. A raw saved manual host is not itself an automatic target.
- **Tokens and races:** every automatic token binds its generation/attempt to the expected `PeerRef` and current Bonjour-or-trusted endpoint key/recovery token. Each dial resolves the latest target snapshot, and TLS readiness rechecks both identity fields. User Connect/Retry cancels scheduled work and advances the generation, so stale automatic callbacks cannot replace or cancel it. If recovery is temporarily deferred because the service is busy, resuming uses the same token and **does not consume an attempt**; stale terminal callbacks may clean up only their own connection instance.
- **Wake/foreground infrastructure first (`onWokeOrActivated`):** always repair the listener before requesting recovery, even while stale UI state still says connected/connecting. Reasserting the non-stealth Bonjour advertisement **and restarting discovery run together behind an independent 3-second debounce**; browser generations reject superseded callbacks, while peer appear/change tokens provide new recovery events. Listener self-repair reuses its ready port within the same App lifetime when possible, so an existing trusted endpoint remains dialable.
- **Codeless reconnect and Retry:** automatic Bonjour and trusted-direct dials always use `pairingCode: nil` and `.requirePinned` with the paired TLS fingerprint. After a successful user bind, Retry keeps the explicit peer or host/port target but becomes codeless; only the user can invoke a raw manual-IP fallback.
- **Explicit disconnect wins:** `lastConnectedPeer` is volatile and cleared by `disconnect()`/`stop()` or peer `.bye`. Local disconnect sends best-effort `.bye` and records a local `PeerRef` suppression so a lost `.bye` cannot permit later codeless inbound reconnect; an explicit local Connect/Retry (or clearing the paired peer) removes that suppression. Peer `.bye` stops recovery without creating local suppression. `stop()` and clearing paired devices also discard learned trusted endpoints; no retained address may bypass these gates.
- **Scope and failure limits:** trusted endpoints and `lastConnectedPeer` are not restored after App restart. If the peer's IP changes while Bonjour is absent, the user must reconnect manually to refresh the address. A listener-port collision may force a random replacement port; if the old bound connection cannot advertise it, direct recovery fails only within the normal 0/2/5/10 window and then waits for another event or manual action.
- `TransferServer` confines all its mutable state to its private serial `queue` (the NWListener callback queue); public methods hop onto it. Don't read its state from the main thread.

### Tests
Pure-logic tests live in `Tests/` as standalone `@main` executables compiled with `swiftc` (NOT an XCTest target), e.g.:
```bash
swiftc -o /tmp/t EasySign/Core/Transfer/*.swift Tests/TransferLoopbackTests.swift && /tmp/t   # exclude TransferService.swift for unit-level tests
```
Expected output ends with `ALL PASS`. Newer tests carry their exact `swiftc` invocation in a header comment; there is no aggregate runner and CI does not run them.
