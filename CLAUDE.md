# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

EasySign is a macOS application for resigning iOS IPA files with new certificates and provisioning profiles. It provides a SwiftUI interface to select IPA/P12/Mobileprovision files and export re-signed IPAs.

## Build Commands

```bash
# Install dependencies (if using CocoaPods)
pod install

# Generate Xcode project (if project.yml exists)
xcodegen generate

# Build the project
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build

# Build release
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Release build
```

## Architecture

### UI Layer (Views/)
- `EasySignApp.swift`: App entry point, creates a 750x670 fixed-size window
- `ContentView.swift`: Main UI with input fields for IPA/P12/mobileprovision files, resign type picker, output directory, and log viewer
- `IPAContentView.swift`: Detail popover for viewing/editing IPA metadata (bundle ID, display name, version, build version, entitlements)
- `ContentViewModel`: ObservableObject managing all state and the resign workflow

### Resign Service Layer (ResignService/)
Core signing logic lives in `ResignService/`:

**Models:**
- `IPA.swift`: Represents an IPA file - extracts Payload/.app to temp workspace
- `AppBundle.swift`: Represents a .app bundle inside IPA, parses Info.plist, manages appex plugins
- `BaseBundle.swift`: Base class for bundle info (bundleId, version, buildVersion) with Info.plist read/write
- `AppexBundle.swift`: Represents .appex plugin bundles inside an app
- `ResignTask.swift`: Main orchestrator - handles the complete resign flow
- `ResignTaskInfo.swift`: Data model for resign parameters (file paths, export type, bundle metadata)
- `PKCS12.swift`: Parses .p12 certificate files using Security framework
- `MobileProvision.swift`: Parses .mobileprovision files, extracts entitlements/certs/team ID
- `SecCertificate.swift`: Wraps Security framework certificate operations
- `Logger.swift`: Simple `LoggerProtocol` for logging during resign operations

**Utilities:**
- `TaskCenter.swift`: Executes shell commands and processes synchronously/asynchronously
- `PathManager.swift`: Provides cache directory and temp workspace paths

**Extensions:**
- `NSError.swift`: Custom error initialization
- `Date.swift`: Date formatting utilities
- `Data.swift`: Data conversion helpers

### Resign Workflow (ResignTask.Start())
1. Extract IPA to temp workspace
2. Update app bundle metadata (bundleId, displayName, version, build)
3. Delete .DS_Store and __MACOSX
4. Optionally copy injected dylibs into the app root and add Mach-O load commands through embedded zsign source
5. Install p12 certificate and mobileprovision
6. Codesign dynamic libraries (.dylib, .framework)
7. Codesign appex plugins with optional separate certificates
8. Update and apply entitlements based on export type
9. Codesign main app bundle
10. Copy to xcarchive template and run `xcodebuild -exportArchive`
11. Copy resulting IPA to output path

### Export Types
`ResignExportType`: app-store, development, ad-hoc, enterprise, validation

### Resources (EasySign/Resources/)
- `resign_template/`: xcarchive template used for `xcodebuild -exportArchive`

### Vendored Dependencies
- `Vendor/OpenSSL/`: Bundled OpenSSL xcframework for zsign crypto operations
- `Vendor/ZSign/`: Embedded zsign source used by the zsign backend and Mach-O dylib injection
- CocoaPods dependencies (Pods/) - including CryptoSwift

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
Expected output ends with `ALL PASS`. The `.sh` files under `Tests/` are stale source-grep checks.
