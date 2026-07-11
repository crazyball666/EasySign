# EasySign zsign Entitlement 通用对账设计

## 1. 背景

EasySign 的 zsign 后端当前从原 App 主可执行文件读取 entitlements，允许用户编辑，然后在 `ResignTask.updateEntitlements` 中修改少量字段，并按“新 provisioning profile 是否包含同名 key”过滤。处理后的 XML 作为单一 `ZSignAsset` 的 entitlements 传给内嵌 zsign，zsign 再递归签名整个 App。

该实现存在系统性问题：

- 只比较 entitlement key，不比较 value；例如原 App 的 `get-task-allow=true` 会被保留，即使企业 profile 中该值为 `false`。
- 根据导出类型猜测 `get-task-allow`、`beta-reports-active`，可能覆盖 profile 的真实授权值。
- 对字符串、数组、嵌套字典以及 profile 通配符没有通用匹配规则。
- `application-identifier` 直接使用 Team ID 拼接 Bundle ID，没有解析 `ApplicationIdentifierPrefix`；二者在历史账号中不保证相同。
- zsign 对 `get-task-allow` 只检查 key 是否存在；即使签入 `<false/>`，仍会设置 `CS_EXECSEG_ALLOW_UNSIGNED`。
- Bridge 只创建一个 `ZSignAsset` 并递归签名所有 appex/Watch bundle，无法为每个 bundle 提供独立 profile 和 entitlement。
- 签名完成后没有再次读取 Mach-O 的实际 entitlements 并与 embedded profile 对账。

Apple 在 TN2415 中说明，安装或启动时系统会校验 App 签名中的 entitlements 与 embedded provisioning profile 是否匹配；不受 profile 允许的 key 或 value 会导致安装失败。

本次现场复现确认“zsign 产物无法安装”，但未保留设备返回的具体错误码；设计依据是已经从代码证明的 `get-task-allow` value mismatch，不依赖猜测某个安装错误编号。

## 2. 目标

本次改动目标：

1. 在 EasySign Swift/Bridge 层实现通用、值级别的 entitlement 对账，不修改 `EasySign/Vendor/ZSign`。
2. 新 profile 是签名权限上限；原 App 或用户输入不能把 profile 未授权的能力带入新签名。
3. 使用策略驱动的授权关系处理 entitlement，而不是假设 profile 与签名中的值必须同类型或结构相等。
4. 正确生成与 Team ID、App ID Prefix、Bundle ID 相关的身份字段。
5. 为 zsign 处理 `get-task-allow=false` 的兼容行为，避免错误设置 `CS_EXECSEG_ALLOW_UNSIGNED`。
6. 签名前给出清晰的删除、改写和拒绝原因；签名后验证实际 Mach-O entitlements。
7. 保持系统 `codesign + xcodebuild -exportArchive` 后端行为不变。
8. 对当前无法安全支持的嵌套 bundle 失败得足够早，不输出看似成功但无法安装的 IPA。

本文“通用”的准确含义是：每个遇到的 entitlement claim 都必须由确定策略证明被允许，或明确失败；它不表示无需 Apple 规则就能自动支持所有未来 key，也不表示支持任意多 bundle/profile 组合。

## 3. 非目标

本次不做：

- 不修改或维护 zsign 上游源码 patch。
- 不新增 appex/Watch 多 profile 选择 UI。
- 不承诺修复证书在线撤销状态、设备信任/MDM 策略、Developer Mode、加密源二进制、应用运行时逻辑等 entitlement 之外的问题。Profile 过期、证书成员关系、Bundle ID pattern 和基础代码签名完整性仍属于本次 fail-fast 范围。
- 不让 zsign 后端调用 `xcodebuild -exportArchive` 兜底。
- 不静默保留无法证明被新 profile 授权的 entitlement。

## 4. 方案比较

### 方案 A：直接使用 profile 的全部 entitlements

优点是简单，不会保留原包中 profile 不存在的 key。缺点是会给 App 添加其未请求的能力，无法正确处理通配符和 Bundle ID 派生值，也会丢失原 App 对 profile 允许值的具体选择。

结论：不采用。

### 方案 B：原 entitlement 与 profile 做通用值级对账

保留原 App 实际需要且被新 profile 允许的权限；移除未授权权限；对系统身份字段进行受控派生；使用策略驱动授权关系处理同类型、跨类型和通配符场景，未知关系默认拒绝。

结论：采用。它能覆盖当前故障以及 Push、Keychain、iCloud、Associated Domains、App Groups 等同类问题，而不针对某个 entitlement 写一次性补丁。

### 方案 C：zsign 后再次调用 Apple 导出工具

可以借助 Xcode 修正部分 entitlement，但重新引入 Xcode 依赖，模糊后端边界，也使 zsign 失去独立后端的意义。

结论：不采用。

## 5. 核心模型

新增纯 Swift 类型，避免把规则继续堆入 `ResignTask`：

```swift
struct EntitlementReconcileRequest {
    let requested: [String: Any]
    let profile: [String: Any]
    let sourceApplicationIdentifier: String?
    let targetBundleIdentifier: String
    let teamIdentifier: String
    let appIdentifierPrefix: String
    let backend: ResignBackend
}

enum EntitlementAuthorizationPolicy {
    case identityDerived
    case booleanClaim
    case profileAuthoritative
    case exact
    case arraySubset
    case wildcardString
    case wildcardArraySubset
    case profileSetContainsScalar
    case profileSetContainsArray
    case recursiveDictionary
    case unsupported
}

struct EntitlementChange: Equatable {
    enum Action: Equatable { case kept, removed, rewritten }
    let keyPath: String
    let action: Action
    let reason: String
}

struct EntitlementReconcileResult {
    let entitlements: [String: Any]
    let changes: [EntitlementChange]
}

enum EntitlementReconcileError: Error {
    case invalidProfile(String)
    case bundleIdentifierNotAllowed(String)
    case incompatibleValue(keyPath: String, requested: Any, allowed: Any)
    case unsupportedValue(keyPath: String)
}
```

实现放在新的 `EntitlementReconciler.swift`，保持 Foundation-only，便于使用独立 `swiftc` 测试。

`MobileProvision` 增加这些已解析字段：

- `appIdentifierPrefixes: [String]`，来源为 profile 顶层 `ApplicationIdentifierPrefix`。
- `applicationIdentifierPattern: String`，来源为 `Entitlements.application-identifier`。
- `teamIdentifierEntitlement: String?`，来源为 `Entitlements.com.apple.developer.team-identifier`。

`sourceApplicationIdentifier` 必须直接从原 Mach-O 签名中读取，并在修改 `Info.plist` 或用户 entitlement 之前采集。它是只读原始身份，用于识别默认 keychain group，不能从用户编辑后的 XML 反推。读取不到时保持 `nil`，此时不执行默认 keychain group 迁移，只允许已能直接匹配新 profile 的自定义 group。

Profile 解析后必须形成唯一签名上下文：

- `applicationIdentifierPattern` 第一个 `.` 之前的部分是实际 App ID Prefix。
- 顶层 `ApplicationIdentifierPrefix` 去重后，必须且只能有一个值等于该 prefix；否则 profile 内部不一致并失败。数组允许包含其他历史 prefix，但不得参与当前 pattern 的派生。
- 顶层 `TeamIdentifier` 去重后必须只有一个值；它必须与 entitlement 中的 team identifier 一致。zsign 会把这个 Team ID 写入 CodeDirectory，因此不允许“优先某一个值”掩盖冲突。

## 6. 输入来源

`requested` 的来源顺序保持用户可预期：

1. 用户在编辑器中提供的合法 XML plist。
2. 否则读取原主可执行文件中实际签入的 entitlements。
3. 原签名不可读时使用空字典，而不是直接复制 profile 的全部权限。

Profile 只表示“允许上限”，不能自动证明 App 需要 profile 中的全部权限。

身份采集和嵌套可执行文件 preflight 必须发生在 `appBundle.update(...)` 之前；当前先修改 Bundle ID 再读取身份的顺序需要调整。

## 7. 通用对账算法

### 7.1 确定性处理顺序

对 `requested` 中每一个 key严格按以下顺序处理：

1. Profile 不包含该 key：直接删除整个 claim 并记录原因；不再解析其内部 value，因此其中的 unsupported 叶子不会阻止删除。
2. Profile 包含该 key：解析 explicit policy；没有 explicit policy 时进入第 7.2 节定义的唯一 fallback。
3. 递归检查该 claim 的全部 requested/profile 叶子是否属于 zsign 支持类型。
4. 执行 policy，并得到保留、改写、缩减或致命错误。

处理结果固定为：

- 身份冲突、profile/requested 类型冲突、未知跨类型授权、未知 wildcard、unsupported 类型：致命错误。
- `exact` 标量不相等：删除整个 key。
- `arraySubset`：删除未授权成员；稳定保留原顺序；按 plist 规范化深相等去重；为空后删除 key。
- `recursiveDictionary`：删除 profile 不存在或 exact 不允许的子 key；类型冲突仍是致命错误；为空后删除父 key。
- Plist dictionary 必须能转换为 `[String: Any]`；非字符串 key 或无法桥接的容器属于致命错误。

处理完成后，只补充第 8 节定义的系统身份字段。其他只存在于 profile、原 App 没有请求的能力不自动加入。

### 7.2 首版完整策略注册表

首版 explicit key registry 固定如下，不使用“至少”“等”形成开放例外：

- `identityDerived`：`application-identifier`、`com.apple.developer.team-identifier`。
- `booleanClaim`：`get-task-allow`、`beta-reports-active`。只有 requested 与 profile 都是 Bool `true` 才签入 `true`；其他 Bool 组合省略 key。
- `profileAuthoritative`：`aps-environment`。Requested 必须是 String，profile 必须是 String；原 App 请求该 key 时结果使用 profile 值。
- `wildcardArraySubset`：`keychain-access-groups`。Requested/profile 必须是 String array；每个 claim 必须匹配 profile 中一个明确值或 TN3125 定义的 prefix wildcard。
- `profileSetContainsScalar`：`com.apple.developer.icloud-container-environment`。Requested 必须是 String；profile 是 String 或 String array；requested 必须是授权集合成员，否则删除 key。
- `profileSetContainsArray`：`com.apple.developer.icloud-services`。Requested 必须是 String array；profile 是 String 或 String array；requested 每个成员必须被允许，不允许成员删除；profile String `*` 在该 key 中表示全成员 allowlist。

未命中 explicit registry 的 key只有一个 fallback：

- Bool/String 标量同类型时使用 `exact`；Bool `false` 规范化为省略 key。
- Array/Dictionary 同类型时使用 `arraySubset`/`recursiveDictionary`，所有叶子只能使用 exact，不解释 wildcard。
- Requested 或 profile 任意 String 含 `*`、两边类型不同、出现 unsupported 叶子时致命失败。

因此 App Group 和 Associated Domains 在 profile/requested 都是普通 String array 时走保守 exact-subset；若 profile 用 wildcard 或其他特殊表示，则安全失败并提示系统后端，不会把 `*` 写进签名。未来确认新的 Apple 特殊关系时，只新增 explicit policy 与 fixture，不改协调器主流程。

### 7.3 类型和删除规则

- Foundation 值分类必须使用 `CFGetTypeID` 区分 `CFBoolean` 与 `NSNumber`，并区分整数与浮点数。
- zsign 当前 DER 编码器支持 Bool、整数、String、Array 和 Dictionary，但其整数编码对一般数值没有足够验证；首版只允许 Bool、String、Array、Dictionary。
- Date、Data、浮点数和普通整数在 zsign 后端首版标记为 `unsupported`，签名前报错并建议切换系统后端；不能让 zsign 内部 assertion 终止进程。
- supported-type 检查必须递归访问每一个数组成员和字典叶子；不能只检查顶层类型。
- 对允许“缩减权限”的策略，不被允许的 key/member 会删除并记录；身份冲突、类型冲突、未知授权关系和 unsupported 类型属于致命错误。
- 数组保持 requested 顺序并去重；结果为空时删除整个 key。
- 字典递归处理 requested 子 key；结果为空时删除整个 key。

所有被删除或改写的路径都记录为 `key`、`key[index]` 或 `key.subkey`，并写入重签日志。

### 7.4 通配符规则

通配符不是通用字符串语法，只在策略表明确标记为 wildcard-aware 的 entitlement 中启用：

- 对 `.`、`+`、`?` 等正则字符先转义。
- `*` 转换为任意字符序列。
- 正则必须使用 `^...$` 全字符串匹配。
- requested 中的 `*` 不作为授权扩张处理。
- 普通 entitlement 值只有在原值能匹配受支持 profile pattern 时才保留；不能根据未知语义自动发明替换值。
- 任意未知 key 出现 `*` 时 fail closed，直到有 Apple 文档与测试 fixture 定义其语义。

## 8. 系统身份字段

少数字段由签名身份决定，不能套用“保留原值”规则：

### `application-identifier`

- 读取 profile 的 `application-identifier` pattern。
- 始终先构造 candidate：`<profile prefix>.<目标 Bundle ID>`。
- 使用完整锚定匹配验证 candidate 是否被 profile pattern 允许；因此同时支持显式 App ID、`PREFIX.*` 和 `PREFIX.com.example.*`。
- 最终签入 candidate，绝不把 wildcard 写入 Mach-O。
- prefix 使用 profile pattern 与顶层 `ApplicationIdentifierPrefix` 共同确认的唯一 App ID Prefix，不假设等于 Team ID。

### `com.apple.developer.team-identifier`

- 使用顶层唯一 `TeamIdentifier`。
- entitlement 中该值存在时必须与顶层值一致，否则失败。
- 这保证 Swift entitlement、zsign `ZSignAsset.m_strTeamId` 和 CodeDirectory Team ID 一致。

### `keychain-access-groups`

- 仅处理原 App 请求的 groups。
- 原 group 与新 profile 允许值直接匹配时保留。
- 原 App 默认 group 精确定义为签名前捕获的 `sourceApplicationIdentifier`；只有与它完全相等的 group 才允许身份迁移。
- 默认 group 重写为新 `application-identifier` candidate，前提是该 candidate 能匹配新 profile `keychain-access-groups` 数组中的某个明确值或受支持 wildcard；这里不使用 profile 的 `application-identifier` pattern 代替 keychain allowlist。
- 自定义 group 无法匹配新 profile 时删除，不能仅替换 Team ID 后假定合法。

### `get-task-allow`

- 不再由 `exportType` 猜测；它使用 `booleanClaim`：只有原 App/用户请求为 `true` 且 profile 也为 `true` 时才签入 `true`。
- 其他情况从最终 XML 完全删除该 key。这既符合“未声明调试能力”的语义，也避免 zsign 因 key 存在而设置 `CS_EXECSEG_ALLOW_UNSIGNED`。
- Apple 后端维持现有导出流程，本次不改变其输入行为。

### 其他系统值

系统管理字段必须使用封闭映射，不能使用“等”形成开放例外。首版：

- `aps-environment` 使用 `profileAuthoritative`。
- `beta-reports-active` 使用 `booleanClaim`。
- iCloud 的两个合法跨类型关系使用第 7.2 节的专用策略。

其他 key 走保守默认关系；遇到未知跨类型关系时失败并建议系统后端。它们不再根据 export type 手工构造。

## 9. zsign 集成

`ResignTask.startZSignResign` 改为：

1. 解析 mobileprovision，包括 App ID Prefix。
2. 读取用户或原 Mach-O entitlements。
3. 调用 `EntitlementReconciler`。
4. 将 changes 逐条写入日志，清楚显示保留、删除和改写。
5. 把结果序列化为 XML plist并传给现有 `ZSignBridgeOptions.entitlementsPath`。
6. 不修改 `ZSignBridge` 调用的 vendored zsign 实现。

`exportType` 仍保留在任务模型中，但 zsign entitlement 生成不再依靠它伪造权限。Profile 是最终授权来源。

## 10. 嵌套 bundle 策略

本次通用性定义为“适用于任意 entitlement key/value 结构”，不伪称当前单 profile UI 已支持任意 bundle 图。

当前 Bridge 只构造一个 `ZSignAsset`，zsign 会把同一份 entitlements 用于所有 `MH_EXECUTE`。因此本次增加递归 Mach-O preflight，而不是依赖当前只扫描顶层 `PlugIns/*.appex` 的 `appexList`：

- 使用 `FileManager.enumerator` 从主 App 根目录递归枚举，预取 `isRegularFile`、`isSymbolicLink` 和 `isDirectory`。
- 不跟随目录 symlink；任何 symlink 标准化解析后逃出 App 根目录时失败。位于根目录内的文件 symlink 不作为独立 Mach-O 扫描对象，由签后 `codesign --verify` 校验资源封装。
- 对 regular file 读取前 4/8 字节。只有 magic 为 `MH_MAGIC`、`MH_CIGAM`、`MH_MAGIC_64`、`MH_CIGAM_64`、`FAT_MAGIC`、`FAT_CIGAM`、`FAT_MAGIC_64` 或 `FAT_CIGAM_64` 时定义为“疑似 Mach-O”，随后必须完整解析 header、slice table、offset、size 和 filetype；magic 不匹配的普通资源忽略。
- Finder alias 等不是 symlink 的文件按 regular file 处理；没有 Mach-O magic 就作为资源忽略。
- 允许目标主可执行文件的所有架构 slice 为 `MH_EXECUTE`。
- 任何其他路径只要任意 slice 是 `MH_EXECUTE` 就拒绝，包括 appex、Watch App、App Clip、XPC/helper 和无 bundle 包装的 helper executable。
- 报错优先查找最近父 bundle 的 Info.plist 并显示 Bundle ID；找不到时显示相对路径。
- framework 与 dylib 的 Mach-O 类型通常为 `MH_DYLIB`/`MH_BUNDLE`，继续由 zsign 递归签名并使用空 entitlement。
- 无法安全解析的疑似 Mach-O 不静默跳过，preflight 失败。
- 对每个 `taskInfo.injectedDylibPaths` 外部输入同样解析 thin/fat 的全部 slice，并要求每个 slice 都是 `MH_DYLIB`；只有 `.dylib` 扩展名不构成信任依据。`MH_EXECUTE`、混合 filetype 或损坏 Mach-O 一律在调用 Bridge 前拒绝。

后续若支持多 profile，需要单独设计 UI、`ResignTaskInfo` 的 bundle-to-profile 映射，并使用 zsign 已有的 multi-asset API。该能力不是本次 entitlement 修复的隐藏依赖。

## 11. 签前与签后验证

### 签前

- profile 必须可解析且未过期。
- Swift 层必须解析 p12，并用证书 DER 或稳定 fingerprint 与 profile 的每个 `DeveloperCertificates` 项逐一比较；没有完全匹配项时失败。不能依赖 `ZSignAsset.Init`，因为正常 p12 自带证书时 zsign 只校验私钥与该证书配对，不校验该证书属于 profile。
- 目标 Bundle ID 必须匹配 profile App ID pattern。
- 顶层 Team ID、entitlement Team ID、App ID Prefix 和 application-identifier pattern 必须通过第 5、8 节的一致性校验。
- 最终 entitlement 的每个 key/value 必须通过 reconciler。
- zsign 最终 entitlement 若不包含 `get-task-allow=true`，不得包含 `get-task-allow` key。

### 签后

新增独立的、throwing 的 `MachOCodeSignatureInspector`，避免把更复杂的安全验证耦合到当前未提交的预览 reader。zsign 返回后将输出 IPA 解压到当前任务工作区并检查主可执行文件：

- Candidate 解压后要求 `Payload` 直属目录恰好存在一个 `.app`；其 Info.plist 的 Bundle ID 必须等于目标 Bundle ID，`CFBundleExecutable` 必须指向 App 根目录内的 regular Mach-O。该路径定义为预期主可执行文件。
- 读取输出 App 根目录中的实际 `embedded.mobileprovision`，要求原始 Data 与用户选择的 profile 完全一致，然后重新解析它；签后 entitlement 对账只使用这个实际内嵌 profile。
- 枚举 thin Mach-O 的唯一 slice，或 fat/fat64 Mach-O 的每一个架构 slice；不得只选择 arm64/第一个 slice。
- 每个 slice 必须存在有效 SuperBlob、XML entitlement slot 和 DER entitlement slot。
- 实现本设计支持类型范围内的 DER entitlement decoder；XML 与 DER 解码后的 plist 必须语义深相等，字典顺序不参与比较。
- 每个 slice 的 XML/DER entitlements 必须与 reconciler 预期结果语义深相等；所有 slice 之间也必须相等。
- 检查每个 slice 的主 CodeDirectory 与全部 alternate CodeDirectory；当 `get-task-allow` 不为 `true` 时，任何 CodeDirectory 的 `execSegFlags` 都不得包含 `CS_EXECSEG_ALLOW_UNSIGNED`。
- 每个 CodeDirectory 的 Team ID 必须等于签前确认的唯一 Team ID，identifier 必须等于目标 Bundle ID。
- CodeDirectory version 不包含 `execSegFlags` 字段时按 `0` 处理；结构长度不足或未知版本布局时失败。
- 再次使用同一 policy registry 证明不存在 profile 未授权的 claim。
- 对解压后的最终 App 再运行递归 Mach-O 扫描，确认预期主可执行文件是唯一包含 `MH_EXECUTE` slice 的路径；这用于捕获动态库注入及未来 Bridge 变更产生的绕过。
- 对每个允许的非 `MH_EXECUTE` Mach-O slice，entitlement slot 必须缺失或语义上是空字典；不得携带主 App entitlement。
- 调用系统自带 `/usr/bin/codesign --verify --deep --strict --verbose=4 <App>` 校验 CMS、CodeDirectory page hashes 和 CodeResources。自定义 inspector 不重复实现密码学验证，只负责 Apple 工具不直接暴露的 entitlement/profile/execSegFlags 一致性。
- 验证失败则删除本次 candidate并抛出明确错误，已有正式输出保持不变。

签后检查器是 EasySign 自己的只读代码，不修改 zsign。

### Inspector 二进制格式边界

- Mach-O/fat 所有整数按 magic 决定大小端；任何加法、乘法、offset+length 在访问前做溢出和文件边界检查。
- SuperBlob 必须是 `CSMAGIC_EMBEDDED_SIGNATURE`；header、index 数组、每个 blob offset/length 必须完全位于 `LC_CODE_SIGNATURE` data range。主可执行 slice 要求恰好一个 XML slot、一个 DER slot、一个主 CodeDirectory；允许多个 alternate CodeDirectory并全部检查。重复关键 slot、重叠或越界一律失败。
- 当前 vendored zsign 固定生成 CodeDirectory version `0x20400`。签后输出出现其他版本即失败，不尝试猜测未来布局。
- DER decoder 只接受 zsign `_DER` 当前会生成的 ASN.1 子集：Boolean `0x01`、UTF8String `0x0c`、Array Sequence `0x30`、Dictionary Set `0x31`，其中每个字典成员是含 UTF8String key 与单一 value 的 Sequence。拒绝 indefinite length、非最短或超出剩余 buffer 的 length、重复 dictionary key、未知 tag、过深嵌套和过多节点。
- 限制沿用 plist 安全边界：最大嵌套深度 64、最大节点数 100,000、单个 slot 最大 16 MiB；超限失败。

### 输出事务

- Bridge 输出不直接写 `taskInfo.outputPath`，而是写目标目录中的隐藏 sibling candidate：`.EasySign-<UUID>.tmp.ipa`，确保最终发布可在同一文件系统 rename。
- 所有签后验证只针对 candidate；失败时只删除本次 candidate，绝不删除或覆盖已有正式输出。
- 验证通过后：目标不存在则 `moveItem`；目标存在则使用同目录 `replaceItemAt` 原子替换。发布失败时保留旧目标并清理 candidate。

## 12. 错误与日志

日志分为：

- `保留`：原值已被 profile 允许。
- `删除`：profile 不存在该权限或不允许该成员。
- `改写`：身份字段或 profile 管理值被规范化。
- `拒绝`：Profile/Bundle ID 不匹配、类型冲突或签后实际结果与预期不同。

不记录 p12 密码、私钥、完整证书数据。Entitlement 值可能包含域名、容器名等应用配置，沿用现有详细日志行为，但错误信息默认只包含 key path；完整 before/after 仅输出到用户主动可见的任务日志。

## 13. 测试策略

新增 Foundation-only 单元测试，至少覆盖：

1. 原 `get-task-allow=true`、profile 为 `false`、zsign 输出删除 key。
2. 原 App Group 存在、profile 不存在时删除。
3. profile 与 requested 均允许 App Group 时保留允许成员并删除越权成员。
4. `aps-environment` 从 development 规范化为 profile 的 production 值。
5. `application-identifier` 显式 App ID 与 wildcard App ID。
6. App ID Prefix 与 Team ID 不同时仍生成正确 identifier。
7. `keychain-access-groups` 默认 group 前缀迁移、自定义 group 保留和删除。
8. 字符串通配符必须全匹配，不能 substring 越权；覆盖 `PREFIX.*` 与 `PREFIX.com.example.*`。
9. Profile 有多个 App ID Prefix 时，必须选择与 application-identifier pattern 一致的唯一 prefix；无匹配或不唯一时失败。
10. 顶层 Team ID 与 entitlement Team ID 不一致时失败。
11. 嵌套数组、字典递归过滤。
12. Bool/NSNumber 类型识别正确，不能把数字 `1` 当 Bool 绕过规则；整数、浮点、Date、Data 在 zsign 首版明确拒绝。
13. profile array 授权 signed string 的 iCloud environment，以及 profile string/array 授权 signed array 的 iCloud services。
14. requested/profile 未定义的跨类型关系失败。
15. 用户 XML 非法时失败。
16. 原 Mach-O entitlement 不可读时从空 requested 开始，不复制 profile 全部能力。
17. P12 证书不属于 profile `DeveloperCertificates` 时失败。
18. 任意嵌套 `MH_EXECUTE`（appex/Watch/App Clip/XPC/helper/无 bundle helper）触发 zsign preflight，并显示 Bundle ID 或路径。
19. `MH_EXECUTE` 重命名为 `.dylib` 时注入前失败；fat 注入文件只要一个 slice 不是 `MH_DYLIB` 就失败。
20. 数组或嵌套字典深处出现整数、浮点、Date、Data 时递归类型检查失败。
21. Profile 不包含某 key 时直接删除，即使该 requested value 内含 unsupported 叶子也不报错。
22. Default exact/subset、所有 explicit policy 和未知 wildcard/cross-type 的完整 registry 分派测试。
23. Symlink 逃出 App 根目录、Mach-O magic 匹配但结构损坏、fat offset/size 溢出时失败。
24. Profile 过期时失败。
25. 输出实际 embedded profile 与所选 profile Data 不一致时失败。
26. 签后验证失败时删除 candidate 并保留已有正式输出；成功时同目录原子发布。

签后检查测试使用合成最小 Mach-O/SuperBlob fixture，覆盖 XML entitlement slot、DER slot、主/alternate CodeDirectory execSegFlags、thin/fat/fat64 的全部 slice、不同 slice 不一致、XML/DER 不一致、截断结构和未知 CodeDirectory 布局。现有 `MachOEntitlementsTests.swift` 的结构可以参考，但新建独立 inspector/test，避免覆盖用户当前未提交的修改。

在依赖源码测试作为回归信号前，先修复 `EntitlementsFallbackSourceTests.sh`、`AppexMainCertificateSourceTests.sh` 等仍引用旧 `EasySign/ResignService/...` 路径的测试。

计划新增文件：

- `EasySign/Core/Resigning/Model/EntitlementReconciler.swift`
- `EasySign/Core/Resigning/Model/MachOExecutableScanner.swift`
- `EasySign/Core/Resigning/Model/MachOCodeSignatureInspector.swift`
- `EasySign/Core/Resigning/Model/ResignOutputPublisher.swift`
- `Tests/EntitlementReconcilerTests.swift`
- `Tests/MachOExecutableScannerTests.swift`
- `Tests/MachOCodeSignatureInspectorTests.swift`
- `Tests/ResignOutputPublisherTests.swift`

合成 signature fixture 由测试内 builder 生成，不保存真实签名材料：Mach-O header + `LC_CODE_SIGNATURE` + SuperBlob；DER 使用第 11 节定义的 zsign ASN.1 子集；CodeDirectory fixture 固定 version `0x20400`，显式传 identifier、Team ID 和 execSegFlags。

回归验证命令使用确定源码列表：

```bash
swiftc EasySign/Core/Resigning/Model/ResignTaskInfo.swift \
  EasySign/Core/Resigning/Model/EntitlementReconciler.swift \
  Tests/EntitlementReconcilerTests.swift \
  -o /tmp/easysign-entitlements-tests
/tmp/easysign-entitlements-tests

swiftc EasySign/Core/Resigning/Model/MachOExecutableScanner.swift \
  Tests/MachOExecutableScannerTests.swift \
  -o /tmp/easysign-macho-scanner-tests
/tmp/easysign-macho-scanner-tests

swiftc EasySign/Core/Resigning/Model/MachOCodeSignatureInspector.swift \
  Tests/MachOCodeSignatureInspectorTests.swift \
  -o /tmp/easysign-signature-tests
/tmp/easysign-signature-tests

swiftc EasySign/Core/Resigning/Model/ResignOutputPublisher.swift \
  Tests/ResignOutputPublisherTests.swift \
  -o /tmp/easysign-output-tests
/tmp/easysign-output-tests

xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build
```

项目回归还必须验证：实际 profile 替换、profile 过期、证书成员匹配、`codesign --verify --deep --strict` 失败传播、任务日志不出现 p12 密码，以及 candidate 发布/清理。无法做成 Foundation-only 的检查放入 App 集成测试或手工验收清单，不能用 source-text 断言代替行为测试。

真实签名 smoke test 属于手工验收，凭据和设备不进入仓库。由测试者在本机通过 UI 选择自己的 p12/profile，并连接已授权设备。使用两组 fixture：

- Development profile：`get-task-allow=true`，包含至少一个受限 capability。
- Enterprise/Distribution profile：`get-task-allow=false`，不包含该 capability。

分别用 zsign 重签同一个无 appex 测试 App，确认输出 entitlement、execSegFlags、`codesign --verify` 与真机安装结果。

## 14. 兼容性和迁移

- Apple 后端不复用新 reconciler，避免本次修复改变 `xcodebuild -exportArchive` 的行为。
- zsign 后端的结果可能比旧版本少一些权限，这是预期安全变化：旧行为会保留 profile 不允许的 value并生成不可安装包。
- UI 的 entitlement 编辑器继续保留；用户输入代表“请求权限”，不是绕过 profile 的授权来源。
- 对包含 appex/Watch 的 IPA，zsign 从“可能输出无效包”变为明确失败；用户可切换系统后端。

## 15. 可行性判断

该设计不依赖修改 zsign。核心协调可使用 Foundation 实现；签后验证需要新增完整的 Mach-O Code Signature inspector 和本设计支持类型范围内的 DER decoder。当前代码已经具备 profile 解析、原 Mach-O entitlement 读取、工作区和双后端分流，因此集成边界清晰，但不能把现有预览 reader 当成完整验证器。

通用性来自三点：

1. entitlement 主流程由策略驱动，不以 App Group 等单一故障 key 为主体；同类授权关系复用同一个 policy。
2. 对 Apple 文档定义的身份、通配符和跨类型授权使用封闭策略表；未知关系 fail closed，而不是误称可自动推断所有未来 entitlement。
3. zsign 无法可靠 DER 编码的值在进入 C++ 前拒绝，避免 assertion 或畸形 DER。
4. 签后检查全部架构、XML/DER slot 和全部 CodeDirectory，验证“计划签入的值”与“真正签入的值”一致。

本设计能消除当前已确认的 entitlement/profile mismatch，但不能把单 profile 输入自动变成完整的多 bundle 签名系统。通过 preflight 拒绝不安全范围，保证本次实现不会对通用性作虚假承诺。

## 16. 参考

- Apple Technical Note TN2415, Entitlements Troubleshooting: https://developer.apple.com/library/archive/technotes/tn2415/_index.html
- Apple Technical Note TN3125, Inside Code Signing: Provisioning Profiles: https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles
- Apple App Groups Entitlement: https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.application-groups
- Apple iCloud Container Environment Entitlement: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.icloud-container-environment
- Apple iCloud Services Entitlement: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.icloud-services
- Apple Code Signing exec segment flags: Xcode SDK `Kernel.framework/Headers/kern/cs_blobs.h`
- 现有 zsign 后端设计：`docs/superpowers/specs/2026-05-30-zsign-backend-design.md`
- 现有 zsign 后端说明：`docs/zsign-backend.md`
