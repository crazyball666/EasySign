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

**Reconnection invariants (subtle — read before touching `maybeAutoReconnect` / `TransferAutoReconnect`):**
- **One-way dial arbitration:** when both ends rediscover each other, only the device with the **smaller deviceId** dials; the other waits for the inbound. This prevents connection **glare** (two competing connections that supersede each other and flap, since the inbound-replaces-active supersede in `inboundReady`/`bindConnected` is not deterministic across ends). Do NOT add an "ignore arbitration / force dial" path — a woke device that can't dial (larger id) must instead become reachable again (below) and let the peer dial in.
- **Wake/foreground handling (`onWokeOrActivated`):** system sleep can drop the listener and its Bonjour advertisement. On `NSWorkspace.didWake` / `NSApplication.didBecomeActive` the service (1) self-heals the listener (`TransferServer` rebuilds on `.failed`; `restartIfUnhealthy()` on wake) and **re-advertises** Bonjour (debounced) so the peer rediscovers it, and (2) restarts discovery + tries an arbitration-respecting reconnect. A failed silent auto-reconnect clears its cooldown so the next discovery refresh can retry immediately.
- `lastConnectedPeer` (volatile) is the auto-reconnect target; cleared on user `disconnect()`/`stop()` and on peer `.bye`.
- `TransferServer` confines all its mutable state to its private serial `queue` (the NWListener callback queue); public methods hop onto it. Don't read its state from the main thread.

### Tests
Pure-logic tests live in `Tests/` as standalone `@main` executables compiled with `swiftc` (NOT an XCTest target), e.g.:
```bash
swiftc -o /tmp/t EasySign/Core/Transfer/*.swift Tests/TransferLoopbackTests.swift && /tmp/t   # exclude TransferService.swift for unit-level tests
```
Expected output ends with `ALL PASS`. Newer tests carry their exact `swiftc` invocation in a header comment; there is no aggregate runner and CI does not run them.
