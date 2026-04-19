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
4. Install p12 certificate and mobileprovision
5. Codesign dynamic libraries (.dylib, .framework)
6. Codesign appex plugins with optional separate certificates
7. Update and apply entitlements based on export type
8. Codesign main app bundle
9. Copy to xcarchive template and run `xcodebuild -exportArchive`
10. Copy resulting IPA to output path

### Export Types
`ResignExportType`: app-store, development, ad-hoc, enterprise, validation

### Resources (EasySign/Resources/)
- `resign_template/`: xcarchive template used for `xcodebuild -exportArchive`
- `resign_tools/optool`: External tool for code signing

### Vendored Dependencies
- `Vendor/OpenSSL/`: OpenSSL xcframework for crypto operations
- CocoaPods dependencies (Pods/) - including CryptoSwift
