# zsign 后端实施计划

> **给执行代理的要求：** 实施本计划时必须使用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans`。所有步骤使用 checkbox（`- [ ]`）跟踪。

**目标：** 在保留现有 Apple `codesign` + `xcodebuild` 重签流程的同时，新增默认的内置 zsign 重签后端。

**架构：** 将现有 App 内置 OpenSSL 替换为单一 OpenSSL 3.5.6 LTS xcframework；把 zsign 源码 vendor 到 App target；通过 Objective-C++ bridge 暴露给 Swift；再用 `ResignEngine` 抽象在 Apple Archive 后端和 zsign 后端之间切换。现有 `ResignTask` 行为迁移为 `AppleArchiveResignEngine`，新增 `ZSignResignEngine` 负责准备 zsign 参数并调用 bridge。

**技术栈：** Swift、SwiftUI、Objective-C++、C++11 zsign 源码、OpenSSL 3.5.6 LTS、Xcode project filesystem synchronized groups。

---

## 文件结构

新增文件：

- `scripts/build-openssl-macos-xcframework.sh`：可复现地构建单一 OpenSSL 3.5.6 LTS xcframework。
- `EasySign/Vendor/OpenSSL/VERSION.txt`：记录 OpenSSL 版本、来源、构建参数和 license。
- `EasySign/Vendor/OpenSSL/LICENSE.txt`：从 OpenSSL 3.5.6 源码包复制。
- `EasySign/Vendor/ZSign/LICENSE`：从 `zhlynn/zsign` 复制。
- `EasySign/Vendor/ZSign/README-EasySign.md`：记录上游 commit 和本地 patch。
- `EasySign/Vendor/ZSign/Sources/...`：vendored zsign C/C++ 源码。
- `EasySign/Vendor/ZSign/Bridge/EZSignBridge.h`：暴露给 Swift 的 Objective-C API。
- `EasySign/Vendor/ZSign/Bridge/EZSignBridge.mm`：封装 zsign 的 Objective-C++ wrapper。
- `EasySign/ResignService/Engine/ResignEngine.swift`：签名后端协议和后端枚举。
- `EasySign/ResignService/Engine/AppleArchiveResignEngine.swift`：从现有 `ResignTask` 迁移出来的 Apple 后端。
- `EasySign/ResignService/Engine/ZSignResignEngine.swift`：Swift 层 zsign 后端，负责工作区和参数映射。

修改文件：

- `EasySign/EasySign-Bridging-Header.h`：导入 `EZSignBridge.h`。
- `EasySign/ResignService/Model/ResignTask.swift`：改成后端分发器。
- `EasySign/ResignService/Model/ResignTaskInfo.swift`：新增 `engineType`。
- `EasySign/Views/ContentView.swift`：新增后端选择器、默认值和 `UserDefaults` 缓存。
- `EasySign.xcodeproj/project.pbxproj`：必要时补充 header search paths 和 OpenSSL framework 设置。
- `EasySign/Vendor/ZSign/Sources/bundle.h`、`bundle.cpp`：本地 patch，让外置版本号和内置 build 号可以分开修改。

不要修改：

- `AGENTS.md`：当前是未跟踪的用户/工作区指令文件。
- `EasySign/DeviceService/*`：和签名后端无关。

## 任务 1：替换内置 OpenSSL 为 3.5.6 LTS

**文件：**

- 新增：`scripts/build-openssl-macos-xcframework.sh`
- 新增：`EasySign/Vendor/OpenSSL/VERSION.txt`
- 新增：`EasySign/Vendor/OpenSSL/LICENSE.txt`
- 替换：`EasySign/Vendor/OpenSSL/OpenSSL.xcframework`
- 必要时修改：`EasySign.xcodeproj/project.pbxproj`

- [ ] **步骤 1：写可复现构建脚本**

创建 `scripts/build-openssl-macos-xcframework.sh`：

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

- [ ] **步骤 2：构建前确认官方 hash**

OpenSSL 官方发布的 `openssl-3.5.6.tar.gz` SHA256：

```text
deae7c80cba99c4b4f940ecadb3c3338b13cb77418409238e57d7f31f2a3b736
```

首次构建前，到 OpenSSL downloads 页面确认该 hash 仍与官方 checksum 一致。

- [ ] **步骤 3：运行 OpenSSL 构建脚本**

运行：

```bash
chmod +x scripts/build-openssl-macos-xcframework.sh
scripts/build-openssl-macos-xcframework.sh
```

期望：命令退出码为 `0`，并生成 `EasySign/Vendor/OpenSSL/OpenSSL.xcframework`。

- [ ] **步骤 4：验证 vendored 版本**

运行：

```bash
rg 'OPENSSL_VERSION_TEXT|OPENSSL_VERSION_STR' EasySign/Vendor/OpenSSL/OpenSSL.xcframework
find EasySign/Vendor/OpenSSL/OpenSSL.xcframework -name opensslv.h -print
```

期望：每个 xcframework slice 只有一套 header tree，版本文本包含 `OpenSSL 3.5.6`。

- [ ] **步骤 5：验证没有第二套 OpenSSL 依赖**

运行：

```bash
rg -n 'OpenSSL|libcrypto|libssl' EasySign.xcodeproj/project.pbxproj EasySign/Vendor -g '!OpenSSL.xcframework/**/Headers/**'
```

期望：只看到目标 `OpenSSL.xcframework` 引用和 metadata，没有 Homebrew、`/usr/local` 或其他 OpenSSL 路径。

- [ ] **步骤 6：OpenSSL 替换后先构建 App**

运行：

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build
```

期望：在接入 zsign 前，项目仍能正常构建。

- [ ] **步骤 7：提交**

```bash
git add scripts/build-openssl-macos-xcframework.sh EasySign/Vendor/OpenSSL EasySign.xcodeproj/project.pbxproj
git commit -m "build: upgrade bundled openssl"
```

## 任务 2：Vendor zsign 源码并应用本地兼容 patch

**文件：**

- 新增：`EasySign/Vendor/ZSign/LICENSE`
- 新增：`EasySign/Vendor/ZSign/README-EasySign.md`
- 新增：`EasySign/Vendor/ZSign/Sources/...`
- 修改：`EasySign/Vendor/ZSign/Sources/bundle.h`
- 修改：`EasySign/Vendor/ZSign/Sources/bundle.cpp`

- [ ] **步骤 1：复制上游源码快照**

使用 `zhlynn/zsign` 上游 commit：

```text
28a64217aa52d44a87a47dbc5e3bd59344c14a5d
```

复制这些内容：

```text
src/*.cpp
src/*.h
src/common/
src/third-party/zlib/
src/third-party/minizip/
LICENSE
```

复制到：

```text
EasySign/Vendor/ZSign/Sources/
EasySign/Vendor/ZSign/LICENSE
```

不要复制 `src/zsign.cpp`，它包含 CLI `main()` 和 getopt 解析，App target 不应该编译它。

- [ ] **步骤 2：记录 vendored source 信息**

创建 `EasySign/Vendor/ZSign/README-EasySign.md`：

```markdown
# zsign Vendored Source

Upstream: https://github.com/zhlynn/zsign
Commit: 28a64217aa52d44a87a47dbc5e3bd59344c14a5d

EasySign local patches:

- Exclude `zsign.cpp` because EasySign calls zsign through `EZSignBridge`.
- Extend `ZBundle::SignFolder` / `ModifyBundleInfo` so `CFBundleShortVersionString` and `CFBundleVersion` can be updated separately.
- Build against the single bundled OpenSSL 3.5.6 LTS xcframework.
```

- [ ] **步骤 3：Patch `bundle.h` 支持分离版本号**

在 `EasySign/Vendor/ZSign/Sources/bundle.h` 中，把两个 `SignFolder` overload 和 `ModifyBundleInfo` 改成接收 short version 与 build version：

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

- [ ] **步骤 4：Patch `bundle.cpp` 支持分离版本号**

更新 call sites 和实现：

```cpp
if (!strBundleId.empty() || !strDisplayName.empty() || !strBundleShortVersion.empty() || !strBundleVersion.empty()) {
    m_bForceSign = true;
    if (!ModifyBundleInfo(strBundleId, strBundleShortVersion, strBundleVersion, strDisplayName)) {
        return false;
    }
}
```

在 `ModifyBundleInfo` 内部加入：

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

- [ ] **步骤 5：确认没有引入 OpenSSL 1.1.1 专用兼容分支**

运行：

```bash
rg -n 'OSSL_PROVIDER|provider.h|OPENSSL_VERSION_NUMBER|OpenSSL_add_all_algorithms' EasySign/Vendor/ZSign/Sources
```

期望：OpenSSL 3 provider 调用允许存在；不要因为 EasySign patch 引入额外 OpenSSL 1.1.1-only fallback。

- [ ] **步骤 6：提交**

```bash
git add EasySign/Vendor/ZSign
git commit -m "vendor: add zsign sources"
```

## 任务 3：新增 Objective-C++ zsign Bridge

**文件：**

- 新增：`EasySign/Vendor/ZSign/Bridge/EZSignBridge.h`
- 新增：`EasySign/Vendor/ZSign/Bridge/EZSignBridge.mm`
- 修改：`EasySign/EasySign-Bridging-Header.h`
- 必要时修改：`EasySign.xcodeproj/project.pbxproj`

- [ ] **步骤 1：创建 bridge header**

创建 `EasySign/Vendor/ZSign/Bridge/EZSignBridge.h`：

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

- [ ] **步骤 2：创建 bridge 实现骨架**

创建 `EasySign/Vendor/ZSign/Bridge/EZSignBridge.mm`：

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

- [ ] **步骤 3：实现 OpenSSL provider 初始化**

加入：

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

- [ ] **步骤 4：实现输入准备与签名调用**

`signWithOptions:error:` 必须完成：

1. 校验必填 string 属性非空。
2. 创建 `tempFolder`。
3. 如果 `inputPath` 是 `.ipa` 或 `.zip`，解压到 `tempFolder/input`。
4. 如果 `inputPath` 是 `.app`，创建 `tempFolder/input/Payload` 并复制 app。
5. 对准备好的 root folder 调用 zsign。
6. 把 root folder 打包到 `outputPath`。

核心代码形态：

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

- [ ] **步骤 5：把 bridge 导入 Swift**

修改 `EasySign/EasySign-Bridging-Header.h`：

```objc
#import "MachOSignature.h"
#import "EZSignBridge.h"
```

- [ ] **步骤 6：必要时修复 project search paths**

如果 Xcode 找不到 zsign headers，在 Debug 和 Release target build settings 中加入：

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

使用 `xcodebuild -create-xcframework` 实际生成的 slice 路径。不要添加 `/usr/local` 或 Homebrew 路径。

- [ ] **步骤 7：构建并处理 C++/linker 问题**

运行：

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build
```

期望：构建成功；如果失败，只应该是本任务内可修复的 zsign/OpenSSL 编译或链接错误。

- [ ] **步骤 8：提交**

```bash
git add EasySign/Vendor/ZSign/Bridge EasySign/EasySign-Bridging-Header.h EasySign.xcodeproj/project.pbxproj
git commit -m "feat: add zsign bridge"
```

## 任务 4：抽象签名后端

**文件：**

- 新增：`EasySign/ResignService/Engine/ResignEngine.swift`
- 新增：`EasySign/ResignService/Engine/AppleArchiveResignEngine.swift`
- 修改：`EasySign/ResignService/Model/ResignTask.swift`
- 修改：`EasySign/ResignService/Model/ResignTaskInfo.swift`

- [ ] **步骤 1：新增后端枚举和协议**

创建 `EasySign/ResignService/Engine/ResignEngine.swift`：

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

- [ ] **步骤 2：给 `ResignTaskInfo` 增加 engine type**

修改 `EasySign/ResignService/Model/ResignTaskInfo.swift`：

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

- [ ] **步骤 3：迁移现有实现到 AppleArchive engine**

创建 `EasySign/ResignService/Engine/AppleArchiveResignEngine.swift`，把当前 `ResignTask` 的实现迁移到后端类型：

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

把 `ResignTask` 里现有 private helpers 移到 `AppleArchiveResignEngine` 的 private extension。原来读取 `self.taskInfo` 的 helper 改成显式接收 `taskInfo`，例如：

```swift
private func getAppBundle(taskInfo: ResignTaskInfo) throws -> AppBundle
private func codesignAppex(appBundle: AppBundle, taskInfo: ResignTaskInfo, logger: LoggerProtocol?) throws -> [(bundleId: String, mobileProvision: MobileProvision)]
private func updateEntitlements(appBundle: AppBundle, mobileProvision: MobileProvision, taskInfo: ResignTaskInfo, logger: LoggerProtocol?) throws -> String
```

- [ ] **步骤 4：确认旧行为仍完整**

迁移后，确认这些方法仍在 `AppleArchiveResignEngine` 中：

```text
getAppBundle(taskInfo:)
codesignAppex(appBundle:taskInfo:logger:)
codesignDynamicLibrary(appBundle:pkcs12:)
codesignApp(appBundle:pkcs12:entitlements:)
createArchiveTemplate(...)
xcodebuildExportArchive(...)
updateEntitlements(...)
updatePlist(url:block:)
```

- [ ] **步骤 5：把 `ResignTask` 改成后端分发器**

修改 `EasySign/ResignService/Model/ResignTask.swift`：

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

如果任务 5 还没有实现，可临时创建 stub：

```swift
struct ZSignResignEngine: ResignEngine {
    init(logger: LoggerProtocol?) throws {}
    func sign(taskInfo: ResignTaskInfo, logger: LoggerProtocol?) throws {
        throw NSError(message: "zsign backend is not implemented")
    }
}
```

- [ ] **步骤 6：抽取后构建**

运行：

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build
```

期望：构建成功；后续选择 Apple Archive 时仍能走旧流程。

- [ ] **步骤 7：提交**

```bash
git add EasySign/ResignService/Engine EasySign/ResignService/Model/ResignTask.swift EasySign/ResignService/Model/ResignTaskInfo.swift
git commit -m "refactor: split resign engines"
```

## 任务 5：实现 `ZSignResignEngine`

**文件：**

- 新增或替换：`EasySign/ResignService/Engine/ZSignResignEngine.swift`

- [ ] **步骤 1：实现工作区创建**

创建 `EasySign/ResignService/Engine/ZSignResignEngine.swift`：

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

- [ ] **步骤 2：实现 entitlements 临时文件生成**

加入：

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

- [ ] **步骤 3：实现参数映射和 bridge 调用**

加入：

```swift
func sign(taskInfo: ResignTaskInfo, logger: LoggerProtocol?) throws {
    defer {
        logger?.log(.INFO, "清理 zsign 工作区目录：\(workspacePath.path)")
        try? FileManager.default.removeItem(at: workspacePath)
    }

    logger?.log(.INFO, "使用 zsign 后端重签名...")
    let entitlementsPath = try writeEntitlementsIfNeeded(taskInfo.entitlements)

    if taskInfo.exportType == .appStore || taskInfo.exportType == .validation {
        logger?.log(.INFO, "提示：App Store/validation 导出建议使用 Apple Archive 后端再次验证。")
    }

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

- [ ] **步骤 4：构建**

运行：

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build
```

期望：构建成功，`ZSignResignEngine` 能链接到 `EZSignBridge`。

- [ ] **步骤 5：提交**

```bash
git add EasySign/ResignService/Engine/ZSignResignEngine.swift
git commit -m "feat: implement zsign engine"
```

## 任务 6：新增 UI 后端选择并默认 zsign

**文件：**

- 修改：`EasySign/Views/ContentView.swift`

- [ ] **步骤 1：新增 cache key**

给 `CacheKey` 添加：

```swift
case selectedSigningBackend = "selected_signing_backend"
```

- [ ] **步骤 2：新增 view model 状态**

给 `ContentViewModel` 添加：

```swift
@Published var signingBackend: ResignEngineType = .zsign
```

- [ ] **步骤 3：在表单中新增 backend picker**

放在当前 resign type picker 附近：

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

- [ ] **步骤 4：保存和恢复 backend**

在 `.onAppear` 中：

```swift
viewModel.signingBackend = ResignEngineType(
    rawValue: UserDefaults.standard.string(forKey: CacheKey.selectedSigningBackend.rawValue) ?? ""
) ?? .zsign
```

在 `onTapStart()` 中：

```swift
UserDefaults.standard.set(viewModel.signingBackend.rawValue, forKey: CacheKey.selectedSigningBackend.rawValue)
```

- [ ] **步骤 5：把 engine type 传入 task info**

更新 `ResignTaskInfo` 初始化：

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

- [ ] **步骤 6：构建**

运行：

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build
```

期望：构建成功；没有缓存值时 UI 默认选中 zsign。

- [ ] **步骤 7：提交**

```bash
git add EasySign/Views/ContentView.swift
git commit -m "feat: add signing backend picker"
```

## 任务 7：验证和打包检查

**文件：**

- 只有验证暴露真实问题时才修改相关文件。

- [ ] **步骤 1：clean build**

运行：

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug clean build
```

期望：干净构建成功。

- [ ] **步骤 2：确认 App 包内只存在一套 OpenSSL**

运行：

```bash
APP_PATH="$(xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -showBuildSettings | awk -F' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR = / { print $2; exit }')/EasySign.app"
test -d "${APP_PATH}"
find "${APP_PATH}" -iname '*openssl*' -print
otool -L "${APP_PATH}/Contents/MacOS/EasySign" | rg 'OpenSSL|crypto|ssl' || true
```

期望：如果使用静态 OpenSSL，不应出现指向 App 外部的 `libcrypto` 或 `libssl` runtime dependency。如果最终退回动态 framework，则 App bundle 内只能有一个 `OpenSSL.framework`。

- [ ] **步骤 3：确认没有外部 zsign 依赖**

运行：

```bash
APP_PATH="$(xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -showBuildSettings | awk -F' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR = / { print $2; exit }')/EasySign.app"
test -d "${APP_PATH}"
find "${APP_PATH}" -name 'zsign' -type f -print
otool -L "${APP_PATH}/Contents/MacOS/EasySign" | rg 'zsign|/usr/local|opt/homebrew' || true
```

期望：没有外部 zsign binary，没有 Homebrew 路径。

- [ ] **步骤 4：错误密码手工 smoke test**

在 UI 中选择 zsign，使用错误 p12 密码运行。

期望：签名失败但错误可读；App 保持响应；日志明确是 zsign 失败。

- [ ] **步骤 5：有效 fixture 手工 smoke test**

使用已知可用的 IPA/app、匹配的 p12、密码和 mobileprovision。

期望：

- zsign 后端把 IPA 写入选择的输出目录。
- IPA 内包含 `Payload/<App>.app`。
- 产物可以在目标 profile 类型支持的设备上安装。

- [ ] **步骤 6：Apple Archive 回归测试**

切换到 Apple Archive 后端，使用同一个 fixture。

期望：现有 `codesign` + `xcodebuild -exportArchive` 流程行为保持不变。

- [ ] **步骤 7：如果验证发现问题则提交修复**

如果验证过程中需要修复：

```bash
git add <fixed-files>
git commit -m "fix: stabilize zsign backend integration"
```

如果没有修复，不要创建空提交。

