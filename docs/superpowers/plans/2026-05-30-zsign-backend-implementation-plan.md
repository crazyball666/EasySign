# zsign Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a bundled zsign signing backend as the default EasySign resign flow while preserving the existing Apple `codesign` + `xcodebuild` backend.

**Architecture:** Replace the existing bundled OpenSSL with one OpenSSL 3.5.6 LTS xcframework, vendor zsign source into the app target, expose zsign through a small Objective-C++ bridge, and route signing through a `ResignEngine` abstraction. The current `ResignTask` behavior becomes `AppleArchiveResignEngine`; the new `ZSignResignEngine` prepares options and calls the bridge.

**Tech Stack:** Swift, SwiftUI, Objective-C++, C++11 zsign sources, OpenSSL 3.5.6 LTS, Xcode project with filesystem synchronized groups.

---

## File Structure

Create:

- `scripts/build-openssl-macos-xcframework.sh` - reproducibly builds the single bundled OpenSSL 3.5.6 LTS xcframework.
- `EasySign/Vendor/OpenSSL/VERSION.txt` - records OpenSSL version, source URL, build flags, and license.
- `EasySign/Vendor/OpenSSL/LICENSE.txt` - copied from the OpenSSL 3.5.6 source archive.
- `EasySign/Vendor/ZSign/LICENSE` - copied from `zhlynn/zsign`.
- `EasySign/Vendor/ZSign/README-EasySign.md` - records upstream commit and local patches.
- `EasySign/Vendor/ZSign/Sources/...` - vendored zsign C/C++ sources.
- `EasySign/Vendor/ZSign/Bridge/EZSignBridge.h` - Objective-C API visible to Swift.
- `EasySign/Vendor/ZSign/Bridge/EZSignBridge.mm` - Objective-C++ wrapper around zsign.
- `EasySign/ResignService/Engine/ResignEngine.swift` - signing backend protocol and backend enum.
- `EasySign/ResignService/Engine/AppleArchiveResignEngine.swift` - old resign flow moved behind the protocol.
- `EasySign/ResignService/Engine/ZSignResignEngine.swift` - Swift wrapper that prepares zsign workspaces and options.

Modify:

- `EasySign/EasySign-Bridging-Header.h` - imports `EZSignBridge.h`.
- `EasySign/ResignService/Model/ResignTask.swift` - becomes a small backend dispatcher.
- `EasySign/ResignService/Model/ResignTaskInfo.swift` - adds `engineType`.
- `EasySign/Views/ContentView.swift` - adds backend picker, default value, and UserDefaults persistence.
- `EasySign.xcodeproj/project.pbxproj` - updates header search paths and OpenSSL framework settings if filesystem synchronization does not infer them cleanly.
- Vendored `EasySign/Vendor/ZSign/Sources/bundle.h` and `bundle.cpp` - local patch so short version and build version can be signed separately.

Do not modify:

- `AGENTS.md` - currently untracked user/workspace instruction file.
- Existing DeviceService files - unrelated to signing backend.

## Task 1: Replace Bundled OpenSSL With 3.5.6 LTS

**Files:**

- Create: `scripts/build-openssl-macos-xcframework.sh`
- Create: `EasySign/Vendor/OpenSSL/VERSION.txt`
- Create: `EasySign/Vendor/OpenSSL/LICENSE.txt`
- Replace: `EasySign/Vendor/OpenSSL/OpenSSL.xcframework`
- Modify: `EasySign.xcodeproj/project.pbxproj` only if framework linkage/embed settings need repair

- [ ] **Step 1: Write the reproducible build script**

Create `scripts/build-openssl-macos-xcframework.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

OPENSSL_VERSION="3.5.6"
OPENSSL_SHA256="deae7c80cba99c4b4f940ecadb3c3338b13cb77418409238e57d7f31f2a3b736"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.build/openssl-${OPENSSL_VERSION}"
VENDOR_DIR="${ROOT_DIR}/EasySign/Vendor/OpenSSL"
SOURCE_URL="https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"
TARBALL="${BUILD_DIR}/openssl-${OPENSSL_VERSION}.tar.gz"
SRC_DIR="${BUILD_DIR}/src"
OUT_DIR="${BUILD_DIR}/out"
XCFRAMEWORK="${VENDOR_DIR}/OpenSSL.xcframework"
MACOS_MIN_VERSION="13.0"

build_arch() {
  local arch="$1"
  local configure_target="$2"
  local prefix="${OUT_DIR}/${arch}"
  local framework_dir="${BUILD_DIR}/frameworks/${arch}/OpenSSL.framework"

  rm -rf "${SRC_DIR}-${arch}" "${prefix}" "${framework_dir}"
  cp -R "${SRC_DIR}" "${SRC_DIR}-${arch}"

  pushd "${SRC_DIR}-${arch}" >/dev/null
  ./Configure "${configure_target}" \
    no-shared \
    no-tests \
    no-apps \
    no-ssl3 \
    no-comp \
    no-zlib \
    no-module \
    enable-legacy \
    "--prefix=${prefix}" \
    "--openssldir=${prefix}/ssl" \
    CFLAGS="-arch ${arch} -mmacosx-version-min=${MACOS_MIN_VERSION}"
  make -j"$(sysctl -n hw.ncpu)"
  make install_sw
  popd >/dev/null

  mkdir -p "${framework_dir}/Headers/openssl" "${framework_dir}/Modules"
  libtool -static -o "${framework_dir}/OpenSSL" "${prefix}/lib/libssl.a" "${prefix}/lib/libcrypto.a"
  rsync -a "${prefix}/include/openssl/" "${framework_dir}/Headers/openssl/"
  cat > "${framework_dir}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>OpenSSL</string>
  <key>CFBundleIdentifier</key>
  <string>org.openssl.OpenSSL</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>OpenSSL</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>${OPENSSL_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${OPENSSL_VERSION}</string>
</dict>
</plist>
PLIST
  cat > "${framework_dir}/Headers/OpenSSL.h" <<'HEADER'
#pragma once
#include <openssl/ssl.h>
#include <openssl/crypto.h>
#include <openssl/pkcs12.h>
#include <openssl/cms.h>
HEADER
  cat > "${framework_dir}/Modules/module.modulemap" <<'MODULEMAP'
framework module OpenSSL {
  umbrella header "OpenSSL.h"
  export *
  module * { export * }
}
MODULEMAP
}

mkdir -p "${BUILD_DIR}" "${VENDOR_DIR}"
if [ ! -f "${TARBALL}" ]; then
  curl -L "${SOURCE_URL}" -o "${TARBALL}"
fi
echo "${OPENSSL_SHA256}  ${TARBALL}" | shasum -a 256 -c -
rm -rf "${SRC_DIR}" "${OUT_DIR}" "${BUILD_DIR}/frameworks"
mkdir -p "${SRC_DIR}"
tar -xzf "${TARBALL}" --strip-components=1 -C "${SRC_DIR}"
cp "${SRC_DIR}/LICENSE.txt" "${VENDOR_DIR}/LICENSE.txt"

build_arch "arm64" "darwin64-arm64-cc"
build_arch "x86_64" "darwin64-x86_64-cc"

rm -rf "${XCFRAMEWORK}"
xcodebuild -create-xcframework \
  -framework "${BUILD_DIR}/frameworks/arm64/OpenSSL.framework" \
  -framework "${BUILD_DIR}/frameworks/x86_64/OpenSSL.framework" \
  -output "${XCFRAMEWORK}"

cat > "${VENDOR_DIR}/VERSION.txt" <<EOF
OpenSSL ${OPENSSL_VERSION} LTS
Source: ${SOURCE_URL}
SHA256: ${OPENSSL_SHA256}
Build: static macOS arm64/x86_64 xcframework
Flags: no-shared no-tests no-apps no-ssl3 no-comp no-zlib no-module enable-legacy
License: Apache License 2.0
EOF
```

- [ ] **Step 2: Confirm the official tarball hash before first build**

OpenSSL publishes `openssl-3.5.6.tar.gz` with SHA256:

```text
deae7c80cba99c4b4f940ecadb3c3338b13cb77418409238e57d7f31f2a3b736
```

Before first build, confirm the hash still matches the official checksum link from the OpenSSL downloads page.

- [ ] **Step 3: Run the OpenSSL build script**

Run:

```bash
chmod +x scripts/build-openssl-macos-xcframework.sh
scripts/build-openssl-macos-xcframework.sh
```

Expected: command exits `0` and writes `EasySign/Vendor/OpenSSL/OpenSSL.xcframework`.

- [ ] **Step 4: Verify the vendored version**

Run:

```bash
rg 'OPENSSL_VERSION_TEXT|OPENSSL_VERSION_STR' EasySign/Vendor/OpenSSL/OpenSSL.xcframework
find EasySign/Vendor/OpenSSL/OpenSSL.xcframework -name opensslv.h -print
```

Expected: exactly one header tree per xcframework slice, and version text mentions `OpenSSL 3.5.6`.

- [ ] **Step 5: Verify there is no second OpenSSL dependency**

Run:

```bash
rg -n 'OpenSSL|libcrypto|libssl' EasySign.xcodeproj/project.pbxproj EasySign/Vendor -g '!OpenSSL.xcframework/**/Headers/**'
```

Expected: only the intended `OpenSSL.xcframework` references and metadata. No Homebrew or `/usr/local` paths.

- [ ] **Step 6: Build the app after the OpenSSL swap**

Run:

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build
```

Expected: build succeeds before zsign integration begins.

- [ ] **Step 7: Commit**

```bash
git add scripts/build-openssl-macos-xcframework.sh EasySign/Vendor/OpenSSL EasySign.xcodeproj/project.pbxproj
git commit -m "build: upgrade bundled openssl"
```

## Task 2: Vendor zsign Source and Apply Local Compatibility Patches

**Files:**

- Create: `EasySign/Vendor/ZSign/LICENSE`
- Create: `EasySign/Vendor/ZSign/README-EasySign.md`
- Create: `EasySign/Vendor/ZSign/Sources/...`
- Modify: `EasySign/Vendor/ZSign/Sources/bundle.h`
- Modify: `EasySign/Vendor/ZSign/Sources/bundle.cpp`

- [ ] **Step 1: Copy the upstream source snapshot**

Use upstream `zhlynn/zsign` commit:

```text
28a64217aa52d44a87a47dbc5e3bd59344c14a5d
```

Copy:

```text
src/*.cpp
src/*.h
src/common/
src/third-party/zlib/
src/third-party/minizip/
LICENSE
```

into:

```text
EasySign/Vendor/ZSign/Sources/
EasySign/Vendor/ZSign/LICENSE
```

Do not copy `src/zsign.cpp`; it contains CLI `main()` and getopt parsing that the app should not compile.

- [ ] **Step 2: Add the vendored-source note**

Create `EasySign/Vendor/ZSign/README-EasySign.md`:

```markdown
# zsign Vendored Source

Upstream: https://github.com/zhlynn/zsign
Commit: 28a64217aa52d44a87a47dbc5e3bd59344c14a5d

EasySign local patches:

- Exclude `zsign.cpp` because EasySign calls zsign through `EZSignBridge`.
- Extend `ZBundle::SignFolder` / `ModifyBundleInfo` so `CFBundleShortVersionString` and `CFBundleVersion` can be updated separately.
- Build against the single bundled OpenSSL 3.5.6 LTS xcframework.
```

- [ ] **Step 3: Patch `bundle.h` for separate versions**

In `EasySign/Vendor/ZSign/Sources/bundle.h`, change both `SignFolder` overloads and `ModifyBundleInfo` to accept both short version and build version:

```cpp
bool SignFolder(ZSignAsset* pSignAsset,
                const string& strFolder,
                const string& strBundleId,
                const string& strBundleShortVersion,
                const string& strBundleVersion,
                const string& strDisplayName,
                const vector<string>& arrDylibFiles,
                const vector<string>& arrRemoveDylibNames,
                bool bForce,
                bool bWeakInject,
                bool bEnableCache,
                bool bRemoveProvision = false);

bool SignFolder(list<ZSignAsset>* pSignAssets,
                const string& strFolder,
                const string& strBundleId,
                const string& strBundleShortVersion,
                const string& strBundleVersion,
                const string& strDisplayName,
                const vector<string>& arrDylibFiles,
                const vector<string>& arrRemoveDylibNames,
                bool bForce,
                bool bWeakInject,
                bool bEnableCache,
                bool bRemoveProvision = false);

bool ModifyBundleInfo(const string& strBundleId,
                      const string& strBundleShortVersion,
                      const string& strBundleVersion,
                      const string& strDisplayName);
```

- [ ] **Step 4: Patch `bundle.cpp` for separate versions**

Update call sites and implementation:

```cpp
if (!strBundleId.empty() || !strDisplayName.empty() || !strBundleShortVersion.empty() || !strBundleVersion.empty()) {
    m_bForceSign = true;
    if (!ModifyBundleInfo(strBundleId, strBundleShortVersion, strBundleVersion, strDisplayName)) {
        return false;
    }
}
```

Inside `ModifyBundleInfo`:

```cpp
if (!strBundleShortVersion.empty()) {
    string strOldShortVersion = jvInfo["CFBundleShortVersionString"];
    jvInfo["CFBundleShortVersionString"] = strBundleShortVersion;
    ZLog::PrintV(">>> BundleShortVersion: %s -> %s\n", strOldShortVersion.c_str(), strBundleShortVersion.c_str());
}

if (!strBundleVersion.empty()) {
    string strOldBundleVersion = jvInfo["CFBundleVersion"];
    jvInfo["CFBundleVersion"] = strBundleVersion;
    ZLog::PrintV(">>> BundleVersion: %s -> %s\n", strOldBundleVersion.c_str(), strBundleVersion.c_str());
}
```

- [ ] **Step 5: Remove OpenSSL 1.1.1-only compatibility if copied**

Run:

```bash
rg -n 'OSSL_PROVIDER|provider.h|OPENSSL_VERSION_NUMBER|OpenSSL_add_all_algorithms' EasySign/Vendor/ZSign/Sources
```

Expected: OpenSSL 3 provider calls are allowed; OpenSSL 1.1.1-only fallback code is not introduced by EasySign patches.

- [ ] **Step 6: Commit**

```bash
git add EasySign/Vendor/ZSign
git commit -m "vendor: add zsign sources"
```

## Task 3: Add the Objective-C++ zsign Bridge

**Files:**

- Create: `EasySign/Vendor/ZSign/Bridge/EZSignBridge.h`
- Create: `EasySign/Vendor/ZSign/Bridge/EZSignBridge.mm`
- Modify: `EasySign/EasySign-Bridging-Header.h`
- Modify: `EasySign.xcodeproj/project.pbxproj` if header search paths or source membership need explicit entries

- [ ] **Step 1: Create the bridge header**

Create `EasySign/Vendor/ZSign/Bridge/EZSignBridge.h`:

```objc
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZSignOptions : NSObject
@property(nonatomic, copy) NSString *inputPath;
@property(nonatomic, copy) NSString *outputPath;
@property(nonatomic, copy) NSString *p12Path;
@property(nonatomic, copy) NSString *p12Password;
@property(nonatomic, copy) NSString *mobileProvisionPath;
@property(nonatomic, copy, nullable) NSString *bundleId;
@property(nonatomic, copy, nullable) NSString *displayName;
@property(nonatomic, copy, nullable) NSString *shortVersion;
@property(nonatomic, copy, nullable) NSString *buildVersion;
@property(nonatomic, copy, nullable) NSString *entitlementsPath;
@property(nonatomic, copy, nullable) NSString *tempFolder;
@end

@interface EZSignBridge : NSObject
+ (BOOL)signWithOptions:(EZSignOptions *)options error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
```

- [ ] **Step 2: Create the bridge implementation skeleton**

Create `EasySign/Vendor/ZSign/Bridge/EZSignBridge.mm`:

```objc
#import "EZSignBridge.h"

#include "bundle.h"
#include "openssl.h"
#include "archive.h"
#include "fs.h"
#include <openssl/opensslv.h>
#if OPENSSL_VERSION_NUMBER >= 0x30000000L
#include <openssl/provider.h>
#endif

@implementation EZSignOptions
@end

static NSString *EZStringOrEmpty(NSString * _Nullable value) {
    return value ?: @"";
}

static std::string EZStdString(NSString * _Nullable value) {
    return std::string(EZStringOrEmpty(value).UTF8String);
}

static void EZSetError(NSError **error, NSString *message) {
    if (!error) { return; }
    *error = [NSError errorWithDomain:@"EasySign.ZSign"
                                 code:1
                             userInfo:@{NSLocalizedDescriptionKey: message}];
}
```

- [ ] **Step 3: Implement provider initialization**

Add:

```objc
static void EZInitializeOpenSSLProviders(void) {
#if OPENSSL_VERSION_NUMBER >= 0x30000000L
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        OSSL_PROVIDER_load(NULL, "default");
        OSSL_PROVIDER_load(NULL, "legacy");
    });
#endif
}
```

- [ ] **Step 4: Implement input preparation**

`signWithOptions:error:` must:

1. Validate required string properties are non-empty.
2. Create `tempFolder` if missing.
3. If `inputPath` is `.ipa` or `.zip`, extract it to `tempFolder/input`.
4. If `inputPath` is `.app`, create `tempFolder/input/Payload` and copy the app there.
5. Sign the prepared root folder.
6. Archive the prepared root folder into `outputPath`.

Expected core shape:

```objc
+ (BOOL)signWithOptions:(EZSignOptions *)options error:(NSError **)error {
    EZInitializeOpenSSLProviders();

    if (options.inputPath.length == 0 || options.outputPath.length == 0 ||
        options.p12Path.length == 0 || options.mobileProvisionPath.length == 0) {
        EZSetError(error, @"zsign options are incomplete");
        return NO;
    }

    NSString *tempRoot = options.tempFolder.length > 0
        ? options.tempFolder
        : [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    NSString *inputRoot = [tempRoot stringByAppendingPathComponent:@"input"];

    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:inputRoot error:nil];
    [fm createDirectoryAtPath:inputRoot withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *ext = options.inputPath.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"ipa"] || [ext isEqualToString:@"zip"]) {
        if (!Zip::Extract(options.inputPath.UTF8String, inputRoot.UTF8String)) {
            EZSetError(error, @"zsign failed to extract IPA");
            return NO;
        }
    } else if ([ext isEqualToString:@"app"]) {
        NSString *payload = [inputRoot stringByAppendingPathComponent:@"Payload"];
        [fm createDirectoryAtPath:payload withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *dest = [payload stringByAppendingPathComponent:options.inputPath.lastPathComponent];
        NSError *copyError = nil;
        if (![fm copyItemAtPath:options.inputPath toPath:dest error:&copyError]) {
            if (error) { *error = copyError; }
            return NO;
        }
    } else {
        EZSetError(error, @"zsign input must be ipa, zip, or app");
        return NO;
    }

    ZSignAsset asset;
    if (!asset.Init("", EZStdString(options.p12Path), EZStdString(options.mobileProvisionPath),
                    EZStdString(options.entitlementsPath), EZStdString(options.p12Password),
                    false, false, false)) {
        EZSetError(error, @"zsign failed to load certificate, private key, or provisioning profile");
        return NO;
    }

    ZBundle bundle;
    bool signedOK = bundle.SignFolder(&asset,
                                      EZStdString(inputRoot),
                                      EZStdString(options.bundleId),
                                      EZStdString(options.shortVersion),
                                      EZStdString(options.buildVersion),
                                      EZStdString(options.displayName),
                                      std::vector<std::string>(),
                                      std::vector<std::string>(),
                                      true,
                                      false,
                                      false);
    if (!signedOK) {
        EZSetError(error, @"zsign signing failed");
        return NO;
    }

    [fm removeItemAtPath:options.outputPath error:nil];
    if (!Zip::Archive(EZStdString(inputRoot), EZStdString(options.outputPath), 0)) {
        EZSetError(error, @"zsign failed to archive IPA");
        return NO;
    }

    return YES;
}
```

- [ ] **Step 5: Import bridge into Swift**

Modify `EasySign/EasySign-Bridging-Header.h`:

```objc
#import "MachOSignature.h"
#import "EZSignBridge.h"
```

- [ ] **Step 6: Fix project search paths if needed**

If Xcode cannot find zsign headers, add to both Debug and Release target build settings:

```text
HEADER_SEARCH_PATHS = (
  "$(inherited)",
  "$(SRCROOT)/EasySign/Vendor/ZSign/Sources",
  "$(SRCROOT)/EasySign/Vendor/ZSign/Sources/common",
  "$(SRCROOT)/EasySign/Vendor/ZSign/Sources/third-party/zlib",
  "$(SRCROOT)/EasySign/Vendor/ZSign/Sources/third-party/minizip",
  "$(SRCROOT)/EasySign/Vendor/OpenSSL/OpenSSL.xcframework/macos-arm64/OpenSSL.framework/Headers",
  "$(SRCROOT)/EasySign/Vendor/OpenSSL/OpenSSL.xcframework/macos-x86_64/OpenSSL.framework/Headers"
);
```

Use the actual slice paths generated by `xcodebuild -create-xcframework`; do not add `/usr/local` or Homebrew paths.

- [ ] **Step 7: Build to catch C++/linker errors**

Run:

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build
```

Expected: build succeeds or fails only with concrete zsign/OpenSSL compile errors to fix in this task.

- [ ] **Step 8: Commit**

```bash
git add EasySign/Vendor/ZSign/Bridge EasySign/EasySign-Bridging-Header.h EasySign.xcodeproj/project.pbxproj
git commit -m "feat: add zsign bridge"
```

## Task 4: Extract Signing Backends

**Files:**

- Create: `EasySign/ResignService/Engine/ResignEngine.swift`
- Create: `EasySign/ResignService/Engine/AppleArchiveResignEngine.swift`
- Modify: `EasySign/ResignService/Model/ResignTask.swift`
- Modify: `EasySign/ResignService/Model/ResignTaskInfo.swift`

- [ ] **Step 1: Add backend enum and protocol**

Create `EasySign/ResignService/Engine/ResignEngine.swift`:

```swift
import Foundation

enum ResignEngineType: String, CaseIterable {
    case zsign = "zsign"
    case appleArchive = "apple_archive"

    var displayName: String {
        switch self {
        case .zsign:
            return "zsign"
        case .appleArchive:
            return "Apple Archive"
        }
    }
}

protocol ResignEngine {
    func sign(taskInfo: ResignTaskInfo, logger: LoggerProtocol?) throws
}
```

- [ ] **Step 2: Add engine type to task info**

Modify `EasySign/ResignService/Model/ResignTaskInfo.swift`:

```swift
struct ResignTaskInfo {
    var engineType: ResignEngineType
    var filePath: URL
    var p12Path: URL
    var p12Password: String
    var mobileProvisionPath: URL
    var appexResignInfos: [String: AppexResignInfo]?
    var exportType: ResignExportType
    var outputPath: URL

    var bundleId: String?
    var displayName: String?
    var version: String?
    var buildVersion: String?
    var entitlements: String?
}
```

- [ ] **Step 3: Move existing implementation to AppleArchive engine**

Create `EasySign/ResignService/Engine/AppleArchiveResignEngine.swift` by moving the current `ResignTask` implementation into a backend type.

```swift
struct AppleArchiveResignEngine: ResignEngine {
    let workspacePath: URL

    init(logger: LoggerProtocol?) throws {
        workspacePath = try PathManager.getCacheDir()
            .appendingPathComponent("ResignTask")
            .appendingPathComponent(Date.now.formatString(format: "yyyyMMddHHmmssSSS"))
        try FileManager.default.createDirectory(at: workspacePath, withIntermediateDirectories: true, attributes: nil)
        logger?.log(.INFO, "工作区目录：\(workspacePath.path)")
    }

    func sign(taskInfo: ResignTaskInfo, logger: LoggerProtocol?) throws {
        defer {
            logger?.log(.INFO, "清理工作区目录：\(workspacePath.path)")
            try? FileManager.default.removeItem(at: workspacePath)
        }

        let appBundle = try getAppBundle(taskInfo: taskInfo)

        logger?.log(.INFO, "开始重签名...")
        logger?.log(.INFO, "修改包体信息...")
        try appBundle.update(
            bundleId: taskInfo.bundleId,
            displayName: taskInfo.displayName,
            version: taskInfo.version,
            buildVersion: taskInfo.buildVersion
        )

        logger?.log(.INFO, "包体信息：")
        logger?.log(.INFO, """
        Bundle ID: \(appBundle.bundleId)
        应用名称：\(appBundle.displayName)
        外置版本号：\(appBundle.version)
        内置版本号：\(appBundle.buildVersion)
        """)

        logger?.log(.INFO, "删除包体内无用文件...")
        try TaskCenter.executeShell(command: "find -d \"\(appBundle.path.path)\" -name \".DS_Store\" -o -name \"__MACOSX\" | xargs rm -rf")

        logger?.log(.INFO, "安装 App p12 文件...")
        let pkcs12 = try PKCS12(file: taskInfo.p12Path, password: taskInfo.p12Password)
        logger?.log(.INFO, "App 证书名称：\(pkcs12.certificate.commonName) Sha1：\(pkcs12.certificate.sha1.hexString)")

        logger?.log(.INFO, "安装 App 描述文件...")
        guard let mobileProvision = try MobileProvision(file: taskInfo.mobileProvisionPath) else {
            throw NSError(message: "读取 App 描述文件异常")
        }
        try mobileProvision.install()
        logger?.log(.INFO, "App 描述文件名称：\(mobileProvision.name), Team ID: \(mobileProvision.teamId)")

        logger?.log(.INFO, "重签动态库...")
        try codesignDynamicLibrary(appBundle: appBundle, pkcs12: pkcs12)

        logger?.log(.INFO, "重签 Appex...")
        let appexResignResult = try codesignAppex(appBundle: appBundle, taskInfo: taskInfo, logger: logger)

        logger?.log(.INFO, "替换 entitlements..")
        let newEntitlements = try updateEntitlements(appBundle: appBundle, mobileProvision: mobileProvision, taskInfo: taskInfo, logger: logger)

        logger?.log(.INFO, "重签 App...")
        try codesignApp(appBundle: appBundle, pkcs12: pkcs12, entitlements: newEntitlements)

        logger?.log(.INFO, "复制 xcarchive 模板到工作区...")
        let archiveTemplate = try createArchiveTemplate(
            appBundle: appBundle,
            pkcs12: pkcs12,
            mobileProvision: mobileProvision,
            appexResignInfo: appexResignResult,
            taskInfo: taskInfo,
            logger: logger
        )

        logger?.log(.INFO, "执行 xcodebuild exportArchive...")
        let ipaPath = try xcodebuildExportArchive(xcarchivePath: archiveTemplate.xcarchivePath, exportOptionsPlistPath: archiveTemplate.exportOptionsPlistPath)

        logger?.log(.INFO, "复制 ipa...")
        if FileManager.default.fileExists(atPath: taskInfo.outputPath.path) {
            try FileManager.default.removeItem(at: taskInfo.outputPath)
        }
        try FileManager.default.copyItem(at: ipaPath, to: taskInfo.outputPath)

        logger?.log(.INFO, "重签名完成🎉🎉🎉")
    }
}
```

Then move all private helper methods currently in `ResignTask` into private extensions on `AppleArchiveResignEngine`. Rename helpers that previously read `self.taskInfo` so they accept `taskInfo` explicitly, for example:

```swift
private func getAppBundle(taskInfo: ResignTaskInfo) throws -> AppBundle
private func codesignAppex(appBundle: AppBundle, taskInfo: ResignTaskInfo, logger: LoggerProtocol?) throws -> [(bundleId: String, mobileProvision: MobileProvision)]
private func updateEntitlements(appBundle: AppBundle, mobileProvision: MobileProvision, taskInfo: ResignTaskInfo, logger: LoggerProtocol?) throws -> String
```

- [ ] **Step 4: Keep old behavior intact**

After moving, confirm these methods still exist in `AppleArchiveResignEngine`:

```text
getAppBundle()
codesignAppex(appBundle:logger:)
codesignDynamicLibrary(appBundle:pkcs12:)
codesignApp(appBundle:pkcs12:entitlements:)
createArchiveTemplate(...)
xcodebuildExportArchive(...)
updateEntitlements(...)
updatePlist(url:block:)
```

Each helper should take `taskInfo` as an argument if it previously read `self.taskInfo`.

- [ ] **Step 5: Turn `ResignTask` into a dispatcher**

Modify `EasySign/ResignService/Model/ResignTask.swift` to:

```swift
struct ResignTask {
    let taskInfo: ResignTaskInfo
    let logger: LoggerProtocol?

    init(taskInfo: ResignTaskInfo, logger: LoggerProtocol?) {
        self.taskInfo = taskInfo
        self.logger = logger
    }

    func Start() throws {
        let engine: ResignEngine
        switch taskInfo.engineType {
        case .zsign:
            engine = try ZSignResignEngine(logger: logger)
        case .appleArchive:
            engine = try AppleArchiveResignEngine(logger: logger)
        }
        try engine.sign(taskInfo: taskInfo, logger: logger)
    }
}
```

Temporarily create a stub `ZSignResignEngine` if Task 5 has not been implemented yet:

```swift
struct ZSignResignEngine: ResignEngine {
    init(logger: LoggerProtocol?) throws {}
    func sign(taskInfo: ResignTaskInfo, logger: LoggerProtocol?) throws {
        throw NSError(message: "zsign backend is not implemented")
    }
}
```

- [ ] **Step 6: Build after extraction**

Run:

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build
```

Expected: build succeeds; selecting Apple Archive later should still exercise old behavior.

- [ ] **Step 7: Commit**

```bash
git add EasySign/ResignService/Engine EasySign/ResignService/Model/ResignTask.swift EasySign/ResignService/Model/ResignTaskInfo.swift
git commit -m "refactor: split resign engines"
```

## Task 5: Implement `ZSignResignEngine`

**Files:**

- Create or replace: `EasySign/ResignService/Engine/ZSignResignEngine.swift`

- [ ] **Step 1: Implement workspace creation**

Create `EasySign/ResignService/Engine/ZSignResignEngine.swift`:

```swift
import Foundation

struct ZSignResignEngine: ResignEngine {
    let workspacePath: URL

    init(logger: LoggerProtocol?) throws {
        workspacePath = try PathManager.getCacheDir()
            .appendingPathComponent("ZSignTask")
            .appendingPathComponent(Date.now.formatString(format: "yyyyMMddHHmmssSSS"))
        try FileManager.default.createDirectory(at: workspacePath, withIntermediateDirectories: true, attributes: nil)
        logger?.log(.INFO, "zsign 工作区目录：\(workspacePath.path)")
    }
}
```

- [ ] **Step 2: Implement entitlements file generation**

Add:

```swift
private extension ZSignResignEngine {
    func writeEntitlementsIfNeeded(_ entitlements: String?) throws -> URL? {
        guard let entitlements, !entitlements.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let data = entitlements.data(using: .utf8),
              (try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]) != nil else {
            throw NSError(message: "新 entitlements 格式异常")
        }
        let path = workspacePath.appendingPathComponent("zsign.entitlements")
        try data.write(to: path)
        return path
    }
}
```

- [ ] **Step 3: Implement option mapping**

Add:

```swift
func sign(taskInfo: ResignTaskInfo, logger: LoggerProtocol?) throws {
    defer {
        logger?.log(.INFO, "清理 zsign 工作区目录：\(workspacePath.path)")
        try? FileManager.default.removeItem(at: workspacePath)
    }

    logger?.log(.INFO, "使用 zsign 后端重签名...")
    let entitlementsPath = try writeEntitlementsIfNeeded(taskInfo.entitlements)

    let options = EZSignOptions()
    options.inputPath = taskInfo.filePath.path
    options.outputPath = taskInfo.outputPath.path
    options.p12Path = taskInfo.p12Path.path
    options.p12Password = taskInfo.p12Password
    options.mobileProvisionPath = taskInfo.mobileProvisionPath.path
    options.bundleId = taskInfo.bundleId
    options.displayName = taskInfo.displayName
    options.shortVersion = taskInfo.version
    options.buildVersion = taskInfo.buildVersion
    options.entitlementsPath = entitlementsPath?.path
    options.tempFolder = workspacePath.path

    var error: NSError?
    guard EZSignBridge.sign(with: options, error: &error) else {
        throw error ?? NSError(message: "zsign 重签名失败")
    }

    logger?.log(.INFO, "zsign 重签名完成：\(taskInfo.outputPath.path)")
}
```

- [ ] **Step 4: Add export type warning**

Before calling the bridge:

```swift
if taskInfo.exportType == .appStore || taskInfo.exportType == .validation {
    logger?.log(.INFO, "提示：App Store/validation 导出建议使用 Apple Archive 后端再次验证。")
}
```

- [ ] **Step 5: Build**

Run:

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build
```

Expected: build succeeds and `ZSignResignEngine` links to `EZSignBridge`.

- [ ] **Step 6: Commit**

```bash
git add EasySign/ResignService/Engine/ZSignResignEngine.swift
git commit -m "feat: implement zsign engine"
```

## Task 6: Add UI Backend Selection and Default to zsign

**Files:**

- Modify: `EasySign/Views/ContentView.swift`

- [ ] **Step 1: Add cache key**

Add to `CacheKey`:

```swift
case selectedSigningBackend = "selected_signing_backend"
```

- [ ] **Step 2: Add view model state**

Add to `ContentViewModel`:

```swift
@Published var signingBackend: ResignEngineType = .zsign
```

- [ ] **Step 3: Add backend picker to the form**

Place this near the current resign type picker:

```swift
HStack {
    Text("Backend")
        .frame(width: 100)
    Picker(selection: $viewModel.signingBackend) {
        ForEach(ResignEngineType.allCases, id: \.rawValue) { option in
            Text(option.displayName)
                .tag(option)
        }
    } label: {}
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
}
.frame(maxWidth: .infinity)
.padding(.horizontal, 8)
.padding(.vertical, 12)
.background(Color.gray.opacity(0.2))
.cornerRadius(10)
```

- [ ] **Step 4: Persist and restore the backend**

In `.onAppear`:

```swift
viewModel.signingBackend = ResignEngineType(
    rawValue: UserDefaults.standard.string(forKey: CacheKey.selectedSigningBackend.rawValue) ?? ""
) ?? .zsign
```

In `onTapStart()`:

```swift
UserDefaults.standard.set(viewModel.signingBackend.rawValue, forKey: CacheKey.selectedSigningBackend.rawValue)
```

- [ ] **Step 5: Pass engine type into task info**

Update the `ResignTaskInfo` initializer call:

```swift
let taskInfo = ResignTaskInfo(
    engineType: viewModel.signingBackend,
    filePath: URL(fileURLWithPath: viewModel.inputFile),
    p12Path: URL(fileURLWithPath: viewModel.p12Path),
    p12Password: viewModel.p12Password,
    mobileProvisionPath: URL(fileURLWithPath: viewModel.mobileprovisionPath),
    appexResignInfos: nil,
    exportType: viewModel.resignType,
    outputPath: URL(fileURLWithPath: viewModel.outputDir).appendingPathComponent(Date.now.formatString(format: "yyyyMMddHHmmss") + ".ipa"),
    bundleId: viewModel.resignSetting?.bundleId,
    displayName: viewModel.resignSetting?.displayName,
    version: viewModel.resignSetting?.version,
    buildVersion: viewModel.resignSetting?.buildVersion,
    entitlements: viewModel.resignSetting?.entitlements
)
```

- [ ] **Step 6: Build**

Run:

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build
```

Expected: build succeeds, and the UI defaults to zsign when no cached value exists.

- [ ] **Step 7: Commit**

```bash
git add EasySign/Views/ContentView.swift
git commit -m "feat: add signing backend picker"
```

## Task 7: Verification and Packaging Checks

**Files:**

- Modify only if verification reveals a real issue.

- [ ] **Step 1: Clean build**

Run:

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug clean build
```

Expected: build succeeds from a clean state.

- [ ] **Step 2: Verify OpenSSL is bundled once**

Find the built app path from the build log or DerivedData, then run:

```bash
APP_PATH="$(xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -showBuildSettings | awk -F' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR = / { print $2; exit }')/EasySign.app"
test -d "${APP_PATH}"
find "${APP_PATH}" -iname '*openssl*' -print
otool -L "${APP_PATH}/Contents/MacOS/EasySign" | rg 'OpenSSL|crypto|ssl' || true
```

Expected for static OpenSSL: no runtime `libcrypto` or `libssl` dependency outside the app. If using dynamic fallback, exactly one `OpenSSL.framework` exists inside the app bundle.

- [ ] **Step 3: Verify no external zsign dependency**

Run:

```bash
APP_PATH="$(xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -showBuildSettings | awk -F' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR = / { print $2; exit }')/EasySign.app"
test -d "${APP_PATH}"
find "${APP_PATH}" -name 'zsign' -type f -print
otool -L "${APP_PATH}/Contents/MacOS/EasySign" | rg 'zsign|/usr/local|opt/homebrew' || true
```

Expected: no external zsign binary and no Homebrew paths.

- [ ] **Step 4: Manual smoke test with bad p12 password**

Use the UI with zsign selected and an intentionally wrong p12 password.

Expected: signing fails with a readable error, the app remains responsive, and logs mention zsign failure.

- [ ] **Step 5: Manual smoke test with a valid fixture**

Use a known-good IPA/app, matching p12, password, and mobileprovision.

Expected:

- zsign backend writes an IPA to the selected output directory.
- The IPA contains `Payload/<App>.app`.
- The app can be installed on the target device for the selected profile type.

- [ ] **Step 6: Manual Apple Archive regression test**

Switch backend to Apple Archive and use the same fixture.

Expected: existing `codesign` + `xcodebuild -exportArchive` flow still works as before.

- [ ] **Step 7: Final status commit if fixes were needed**

If verification required fixes:

```bash
git add <fixed-files>
git commit -m "fix: stabilize zsign backend integration"
```

If no fixes were needed, do not create an empty commit.
