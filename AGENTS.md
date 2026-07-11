# AGENTS.md

Guidance for Codex and other coding agents working in this repository.

**The authoritative guidance is [`CLAUDE.md`](CLAUDE.md)** — it applies verbatim to Codex. Read it for build commands, the layered architecture, the two resign backends, and (important) the Transfer subsystem's reconnection invariants. Keeping a single source here avoids the two copies drifting apart.

Deep architecture reference: [`docs/architecture.md`](docs/architecture.md). Resign-backend detail: [`docs/zsign-backend.md`](docs/zsign-backend.md).

Quick facts:
- macOS SwiftUI app; a 4-tool toolbox (Resign / QRCode / Devices / Transfer) plus `EasySignQuickLook` & `EasySignThumbnail` app extensions.
- Build: `xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build`. No CocoaPods, no xcodegen; CryptoSwift via SPM; deployment target macOS 14.0.
- Xcode 16 synchronized folder groups: new `.swift` under `EasySign/` auto-joins the target — no `project.pbxproj` edit needed.
- Tests are standalone `swiftc @main` executables in `Tests/` (not XCTest); each prints `ALL PASS` on success.
