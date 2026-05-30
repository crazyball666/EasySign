# EasySign zsign 重签后端设计

## 1. 背景与目标

EasySign 当前已有一套基于 Apple 工具链的重签流程：解包 IPA 或复制 `.app`，修改包体信息，读取 p12 和 mobileprovision，调用 `/usr/bin/codesign` 重签动态库、扩展和主 App，再通过 `xcodebuild -exportArchive` 导出 IPA。

本次目标是在保留现有逻辑的前提下，新增 zsign 重签后端，并将默认后端切换为 zsign。默认 zsign 后端必须做到用户只需要安装 EasySign.app 即可使用，不需要安装 Homebrew、zsign、OpenSSL、Xcode command line tools 或其他环境依赖。保留的 Apple/Xcode 后端继续沿用现有 `codesign` 和 `xcodebuild` 行为；如果用户主动选择该后端，它仍然需要对应的 Apple 工具链环境。

## 2. 明确决策

- 保留现有 Apple/Xcode 重签逻辑，作为可选后端。
- 新增 zsign 后端，默认选中 zsign。
- 不维护两套 OpenSSL。替换当前 App 内的 OpenSSL 1.1.1t，统一升级到 OpenSSL 3.5 LTS 系列。
- 当前设计固定目标为 OpenSSL 3.5.6 LTS。按 OpenSSL 官方下载页，3.5.6 是 2026-04-07 发布的 3.5 LTS 最新版本，3.5 LTS 支持到 2030-04-08。
- 不选择 OpenSSL 4.0.0 作为当前目标。虽然它是最新 major release，但不是 LTS，支持周期明显短于 3.5 LTS。
- zsign 以源码级方式接入，优先与项目内 OpenSSL 3.5.x 统一编译和链接。
- 不把用户机器上的 `/usr/local`、Homebrew、系统 OpenSSL 或外部 zsign 当作运行依赖。
- zsign 后端失败时不自动静默 fallback 到 Apple/Xcode 后端。失败信息进入日志，用户可手动切换后端重试。

参考：

- zsign: https://github.com/zhlynn/zsign
- OpenSSL downloads: https://www.openssl-library.org/source/
- OpenSSL roadmap: https://openssl-library.org/roadmap/

## 3. 后端模型

新增签名后端枚举：

```swift
enum ResignEngineType: String, CaseIterable {
    case zsign
    case appleArchive
}
```

新增签名后端协议：

```swift
protocol ResignEngine {
    func sign(taskInfo: ResignTaskInfo, logger: LoggerProtocol?) throws
}
```

现有 `ResignTask` 的实现迁移为 `AppleArchiveResignEngine`。迁移时尽量保持行为不变：

- 继续使用 `PKCS12`、`MobileProvision`、`AppBundle`、`AppexBundle` 等现有模型。
- 继续安装 mobileprovision 并通过 `codesign`/`xcodebuild` 导出。
- 保留 export type 对 `xcodebuild -exportArchive` 的影响。

新增 `ZSignResignEngine`：

- 使用同一个 `ResignTaskInfo` 输入。
- 支持 `.ipa`、`.zip`、`.app`。
- 支持 p12 + password + mobileprovision。
- 支持 bundle id、display name、version/build version、entitlements 覆盖。
- 输出 IPA 到 `taskInfo.outputPath`。
- 使用 zsign 自己的签名、CodeResources 生成和 IPA 打包能力。

## 4. OpenSSL 升级设计

当前项目内的 OpenSSL 是 `OpenSSL.xcframework`，其中 macOS slice 是动态 framework，版本为 1.1.1t。它需要被替换为单一的 OpenSSL 3.5.x 内部依赖。

目标产物：

```text
EasySign/Vendor/OpenSSL/OpenSSL.xcframework
```

优先级：

1. 静态 `OpenSSL.xcframework`，包含 macOS arm64 和 x86_64。
2. 如果静态 framework 在 Xcode 集成或 modulemap 上成本过高，则使用动态 framework，但必须随 EasySign.app 打包，不能依赖用户环境。

要求：

- 删除旧 1.1.1t headers 和 binary，避免同名 header 混用。
- zsign 和 EasySign 均链接同一套 OpenSSL。
- LICENSE/NOTICE 随 vendored dependency 保留。OpenSSL 3.x 使用 Apache License 2.0。
- 不启用 FIPS 模式；本功能只需要 p12、X509、CMS、EVP 等签名能力。

## 5. zsign 源码接入设计

新增目录：

```text
EasySign/Vendor/ZSign/
├── LICENSE
├── Sources/
│   ├── archo.cpp
│   ├── macho.cpp
│   ├── bundle.cpp
│   ├── signing.cpp
│   ├── openssl.cpp
│   ├── common/
│   └── third-party/
└── Bridge/
    ├── EZSignBridge.h
    └── EZSignBridge.mm
```

`EZSignBridge` 提供 Objective-C++ API 给 Swift 调用，避免 Swift 直接感知 C++ 类型：

```objc
@interface EZSignOptions : NSObject
@property(nonatomic, copy) NSString *inputPath;
@property(nonatomic, copy) NSString *outputPath;
@property(nonatomic, copy) NSString *p12Path;
@property(nonatomic, copy) NSString *p12Password;
@property(nonatomic, copy) NSString *mobileProvisionPath;
@property(nonatomic, copy, nullable) NSString *bundleId;
@property(nonatomic, copy, nullable) NSString *displayName;
@property(nonatomic, copy, nullable) NSString *bundleVersion;
@property(nonatomic, copy, nullable) NSString *entitlementsPath;
@property(nonatomic, copy, nullable) NSString *tempFolder;
@end

@interface EZSignBridge : NSObject
+ (BOOL)signWithOptions:(EZSignOptions *)options
                  error:(NSError **)error;
@end
```

`ZSignResignEngine` 负责把 Swift 模型转换成 `EZSignOptions`：

- 如果用户编辑了 entitlements，将 XML plist 写入工作区临时文件，并传给 zsign。
- 如果输入是 IPA/zip，可直接交给 zsign 处理并传输出路径。
- 如果输入是 `.app`，在工作区复制后交给 zsign，避免修改用户原始文件。
- 使用工作区作为 zsign temp folder，避免 zsign 写入不可控的全局临时目录。

## 6. UI 与默认行为

在 Resign 页面新增签名后端选择：

```text
Signing Backend: [zsign] [Apple Archive]
```

默认值：

- 首次启动默认 `zsign`。
- 用户选择后缓存到 `UserDefaults`。

文案：

- `zsign`: Fast bundled signer
- `Apple Archive`: codesign + xcodebuild

`ResignTaskInfo` 新增：

```swift
var engineType: ResignEngineType
```

`onTapStart()` 根据 `engineType` 选择后端。

## 7. 数据流

zsign 后端：

```text
UI 表单
  -> ResignTaskInfo(engineType: .zsign)
  -> ZSignResignEngine
  -> 创建工作区
  -> 生成临时 entitlements 文件（如需要）
  -> EZSignBridge
  -> zsign C++ 源码
  -> 写出 IPA
  -> 清理工作区
```

Apple Archive 后端：

```text
UI 表单
  -> ResignTaskInfo(engineType: .appleArchive)
  -> AppleArchiveResignEngine
  -> 现有 ResignTask 流程
  -> codesign
  -> xcodebuild -exportArchive
  -> 写出 IPA
  -> 清理工作区
```

## 8. 错误处理与日志

统一错误模型：

- Swift 层抛出 `NSError(message:)` 或已有 `TaskError`。
- Objective-C++ bridge 捕获 zsign 失败并返回 `NSError`。
- zsign 日志需要接入 `LoggerProtocol`。第一阶段可以记录关键步骤和最终错误；后续再把 zsign `ZLog` 改为 callback。

必须暴露的错误：

- p12 密码错误。
- mobileprovision 不存在或无法解析。
- p12 与 mobileprovision 内证书不匹配。
- 输入 IPA/app 格式非法。
- OpenSSL 初始化或 CMS 生成失败。
- 输出 IPA 写入失败。

不做静默 fallback。这样用户能明确知道当前产物来自哪个签名引擎。

## 9. 兼容性与风险

### 9.1 App Store 导出

Apple/Xcode 后端仍是 App Store 或 validation 类型的保守选择，因为它使用 `xcodebuild -exportArchive`，更贴近 Apple 官方导出语义。

zsign 后端仍允许用户选择 app-store 类型，但 UI 或日志应提示：如用于 App Store 提交，建议使用 Apple Archive 后端验证。

### 9.2 Appex 多描述文件

当前 UI 还没有完整暴露 appex 单独 p12/mobileprovision 的配置，现有 `ResignTaskInfo.appexResignInfos` 也没有从主界面填入。zsign 支持多个 `-m` provisioning profile，但第一阶段先对齐当前 UI 能力：

- 主 App 使用主 mobileprovision。
- 如果后续 UI 支持 appex profile，再把多 profile 传入 zsign。

### 9.3 OpenSSL 3 迁移

OpenSSL 3 兼容大部分 1.1.1 API，但部分 API 废弃或 provider 行为不同。zsign 需要 legacy provider 支持某些旧 p12 加密格式时，应在 bridge 初始化阶段显式加载 provider，或在 OpenSSL build 中保留 legacy provider。

### 9.4 Vendored 源码体积

zsign 源码体积较小，适合 vendored；OpenSSL 3.5.x binary 体积会增加，需要在最终 App 包大小中确认。

## 10. 测试策略

构建验证：

- `xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build`
- 验证 App bundle 中只存在一套 OpenSSL。
- 验证 zsign bridge 能链接并加载。

单元或集成验证：

- p12 密码错误时返回可读错误。
- mobileprovision 缺失时返回可读错误。
- zsign 后端能对测试 `.app` 或 IPA 输出 IPA。
- Apple Archive 后端仍能走原有流程。
- 用户切换 backend 后，`UserDefaults` 能保存并恢复。

手工验证：

- 默认启动时签名后端为 zsign。
- zsign 成功产物能在目标设备安装。
- Apple Archive 后端产物与当前版本行为一致。

## 11. 实施顺序

1. 替换 OpenSSL 为 3.5.6 LTS 单一内部依赖。
2. 引入 zsign 源码和 Objective-C++ bridge。
3. 抽象 `ResignEngine`，迁移现有逻辑为 Apple Archive 后端。
4. 实现 `ZSignResignEngine`。
5. 更新 UI 后端选择和默认值。
6. 补充构建验证和基本签名错误验证。
