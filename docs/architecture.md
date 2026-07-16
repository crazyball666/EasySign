# EasySign 架构设计

> 本文是 [README 「架构」章节](../README.md#架构) 的深入版,面向要改动代码的人:讲清**分层依赖规则**、**插件化工具模型与依赖注入契约**、**各子系统的分层与不变量**、**应用扩展的代码共享方式**,以及**已知的架构债务与边界**。
>
> 重签后端的细节见 [`docs/zsign-backend.md`](./zsign-backend.md);互传的可靠性不变量另见 `CLAUDE.md` 的 “Transfer / 互联” 一节。

---

## 1. 分层与依赖规则

三层,依赖**只向下流**,不允许回指:

```
App        应用外壳:入口、侧边栏、菜单栏常驻、设置、更新 UI
  │  依赖 ↓
Features   各工具的 SwiftUI 视图(按工具分目录)
  │  依赖 ↓
Core       底层引擎与服务(不含 UI):Toolkit / Resigning / Devices / Transfer / QR / Update / Storage / Logging / UI
```

规则:

- **App / Features → Core**:允许。视图通过 `ServiceHub` 拿到共享服务,或直接调用 Core 的类型。
- **Core 不得 import Features / App**:Core 是可复用引擎,不能反向依赖界面。当前有一处**违反**:`Core/UI/ProgressTimeline` 依赖 `Features/Resign/ResignStages.ResignStage`(见 §7)。
- **Core 内部**:各子系统(Resigning / Devices / Transfer / …)彼此**不应**直接依赖,横切能力通过 `Core/Toolkit`(DI)、`Core/Logging`、`Core/Storage`、`Core/UI` 共享。当前 Transfer 与 Devices 各自实现了文件分块/进度/分帧,**没有**共享(见 §7 技术债)。

---

## 2. 插件化工具模型 + 依赖注入(`Core/Toolkit`)

这是整个应用可扩展性的核心契约,四个文件:`Tool.swift`、`ToolCategory.swift`、`ToolRegistry.swift`、`ServiceHub.swift`(+ `ServiceKey.swift`、`ToolError.swift`)。

### 2.1 `Tool` 协议

一个"工具 tab"是一个**值类型**,声明展示元数据 + 它需要的服务 + 一个建视图的工厂方法:

```swift
protocol Tool: Identifiable {
    var displayName: String { get }
    var subtitle: String { get }
    var icon: String { get }              // SF Symbol
    var accentColor: Color { get }
    var category: ToolCategory { get }
    var sortOrder: Int { get }
    var requiredServices: Set<ServiceKey> { get }   // 能力清单
    func makeContentView(hub: ServiceHub) -> AnyView
}
```

### 2.2 注册与导航

所有工具集中注册在一个数组里 —— `ToolRegistry.allTools`:

```swift
static let allTools: [any Tool] = [ ResignTool(), QRCodeTool(), DevicesTool(), TransferTool() ]
```

- `SidebarView` 按 `ToolCategory` 分组、按 `sortOrder` 排序渲染侧边栏行,行用 `tool.id` 标识。
- `RootView` 把选中的 id 经 `ToolRegistry.tool(forId:)` 解回 `Tool`,调用 `tool.makeContentView(hub:)` 填充详情区。

### 2.3 依赖注入:`ServiceHub`

`ServiceHub` 是**唯一的组合根**:一个 `final class`,持有全部 App 生命周期服务,`ServiceHub.live()` 是唯一构造+接线处,在 `EasySignApp.init()` 里建一次,以 `@State` 持有,向下传。

| 服务 | 类型 | 说明 |
|---|---|---|
| `logger` | `LoggerService` | 结构化日志缓冲 |
| `settings` | `SettingsStore` | `UserDefaults` 之上的类型化设置 |
| `recent` | `RecentFilesService` | 最近文件(recent.json) |
| `artifact` | `ArtifactStore` | 重签产物记录(artifacts.json) |
| `device` | `DeviceService`(`.shared`) | 设备服务门面 |
| `transfer` | `TransferService` | 互传门面 |
| `update` | `UpdateService` | 应用内更新 |

`ServiceKey` 枚举 + `ServiceHub` 下标解析器 + DEBUG 期 `validate()`(断言每个工具的 `requiredServices` 都已注册)构成注入契约的一致性校验。

> ⚠️ 现状:这套 DI 只落实了一半 —— `device` 走的是全局单例 `DeviceService.shared` / `DeviceManager.shared`,`hub.device` 接了线但没人从 hub 读;`requiredServices` 只在 DEBUG 校验"hub 是否注册过",并不保证视图真收到,当前 4 个工具里 3 个在 `makeContentView` 里自建服务、无视清单。详见 §7。

### 2.4 如何加一个新工具

1. 在 `Features/<Name>/` 下写视图 `NameView`。
2. 写 `NameTool: Tool`(照抄现有 16 行的 `*Tool.swift`),填元数据、`requiredServices`、`makeContentView`。
3. 若需新服务:在 `ServiceKey` 加 case、在 `ServiceHub` 加存储属性 + init 参数 + 下标 case、在 `ServiceHub.live()` 构造它。
4. 把 `NameTool()` 追加进 `ToolRegistry.allTools`。

**复用现有服务的工具 = 一个新文件 + 一行注册。** 需要新服务时是 4 处联动改动(见 §7 的扩展性说明)。

---

## 3. 子系统设计

### 3.1 重签(`Core/Resigning` + `Features/Resign`)

详细流程见 [`docs/zsign-backend.md`](./zsign-backend.md),这里只讲结构。

**入口与编排**:`ResignContentView` 校验输入 → 组装值类型 `ResignTaskInfo` → 后台队列 `ResignTask(taskInfo:logger:).start()`。后端选择是 `switch taskInfo.backend`(`.zsign` / `.apple`),**不是协议**,两条路径各是 `ResignTask` 上的一个大私有方法。

**两套后端**:
- `.apple`(旧):`codesign` 逐个签名 + 拷入 xcarchive 模板 + `xcodebuild -exportArchive`。**无签后校验**,发布是非原子的 `remove + copy`。
- `.zsign`(默认):内嵌 zsign(`Vendor/ZSign`)经单一 Obj-C 门面 `ZSignBridge` 就地递归签名 + 打包。**这条路径的新层是全库的设计范本**:
  - `EntitlementReconciler` —— 纯策略,值类型、无 I/O,产出可审计的变更列表。
  - `MachOExecutableScanner` / `MachOCodeSignatureInspector` —— 纯解析,`Data` 进、有界检查,做拓扑与签名结构校验。
  - `ZSignProfileContext` —— 描述文件 → zsign 路径的校验边界。
  - `ResignOutputPublisher` —— 事务发布(候选 `.tmp.ipa` → `replaceItemAt` 原子改名)。
  - **检查(MachO*)/ 策略(Reconciler)/ 发布(Publisher)三者干净分离。**

**C++ 边界**:Swift 从不碰 zsign 内部,只通过 `ZSignBridge.resignWithOptions:error:` 传一个 `ZSignBridgeOptions` 值对象。换签名引擎 = 重实现这一个方法。

### 3.2 互传(`Core/Transfer` + `Features/Transfer`)

分层:**传输 → 编解码 → 门面 → UI**。

- **传输**:`TransferConnection` 包一个 `NWConnection`(WS 分帧、TLS 叶证书指纹读取);`TransferServer` 包 `NWListener` + Bonjour 广播;`TransferClient` 主动拨号。
- **编解码**:`WireMessage`(控制/剪贴板消息的 `enum` + `Envelope: Codable`);`FileTransferManager`(文件二进制分块帧)。
- **门面**:`TransferService`(`ObservableObject`),UI 唯一入口。
- **UI**:`TransferToolView` 只读 `@ObservedObject` 的 published 状态、调 `connect()` 等,**碰不到 `NWConnection`**(好边界)。

**信任与重连不变量**(改 `TransferReconnectCoordinator` / 配对逻辑前必读 `CLAUDE.md` 对应段):首配用 6 位码 + HMAC 绑定证书指纹;已配对**免码**,靠 TLS 证书指纹钉扎。已绑定连接还会交换监听端口:接收方把端口与该 TLS 连接实际观察到的远端 IP 组合成 App 生命周期级可信 endpoint。它只是在 Bonjour 缺失时提供地址,不是新的信任根。自动恢复由意外断线、睡醒/回前台、网络首次可用或恢复、匹配 Bonjour 设备出现/变化或可信 endpoint 变化驱动;每个 generation 只按 **0/2/5/10 秒**尝试,四次失败后进入无 timer 的等待状态,直到新的有效事件重开周期。同一 endpoint 的重复事件不会重置活动周期。

`TransferReconnectCoordinator` 是纯状态机,`TransferReconnectExecutionPolicy` 固定服务动作顺序和门禁,`TransferNetworkMonitor`/`PeerDiscovery` 提供路径转换与带 generation/change token 的事件。其关键约束是:

- 只有 deviceId 较小的一端主动拨号;较大端只修复 listener/Bonjour 并等待入站。自动拨号还要求网络 path 已 satisfied、`lastConnectedPeer` 对应 `PeerRef` 仍已配对。目标优先当前 Bonjour 匹配项;Bonjour 缺失时才回退同一 `PeerRef` 的可信 IP/端口。可信 endpoint 不能绕过这些门禁,保存的原始手动 host 也不会自动升级成可信目标。
- 自动 token 同时绑定 generation、attempt、预期 `PeerRef`(deviceId + fingerprint)与 Bonjour/可信 endpoint key;每次拨号从最新 snapshot 解析目标,TLS ready 后再次核对身份。用户 Connect/Retry 会取消定时任务并推进 generation;忙碌导致的 deferred recovery 保留原 token/attempt,不消耗尝试次数;旧回调只能清理自己的连接实例。
- 睡醒/网络恢复始终先修 listener,最后才请求恢复;非隐身模式的 Bonjour 广告重声明与 discovery 重启组成同一组 repair 动作,**共同受独立 3 秒去抖控制**,旧 browser generation 回调会被拒绝。listener 在同一 App 生命周期的自愈中优先复用已 ready 的端口;端口被占用时才降级到随机端口并继续有限失败策略。
- 自动 Bonjour/可信直连都永远不带配对码,并以已配对指纹执行 TLS pinning。成功绑定后,手动 Retry 保留用户明确选择的 peer 或 host/port,但改走免码路径;原始手动 IP 仅能由用户显式触发。
- 主动断开先使 recovery generation 失效,再发送 best-effort `.bye`,并把当前 `PeerRef` 加入本机抑制集合;即使 `.bye` 丢失也拒绝该设备后续免码入站,直到本机显式 Connect/Retry 或清除配对。对端 `.bye` 只停止目标恢复,不建立本机抑制。`stop()` 与清除配对会删除可信 endpoint;显式断开、停止或清配对都不能被旧地址绕过。
- 能力边界保持保守:若对端 IP 已变化且 Bonjour 不可用,仍需手动重连以学习新地址;App 重启后 `lastConnectedPeer` 与可信 endpoint 都不恢复。listener 端口若被其他进程占用且旧连接已断,对端无法预先得知随机新端口,本轮按 0/2/5/10 有限失败后等待新事件或手动操作。

**并发**:全手写 GCD —— 每连接一个串行队列 + `NSLock`,`TransferServer` 把状态收敛在自己的串行队列,`TransferService` 靠遍布的 `DispatchQueue.main.async` 隐式主线程收敛。无 actor / async-await。

> ⚠️ 自动重连状态与纯门禁已抽到 coordinator/policy,但 `TransferService` 仍是大型门面,负责 Network.framework 回调、连接生命周期、配对与文件传输编排,见 §7。

### 3.3 设备(`Core/Devices` + `Features/Devices`)

基于系统私有 `MobileDevice.framework` + **自实现**的 AFC / HouseArrest / InstallationProxy(不依赖 libimobiledevice —— 原因见用户记忆 `device-stack-mobiledevice`)。

**传输分层是全库最干净的一段**:

```
AFCTransport(协议,抽象字节通道)
  └ AFCServiceConnectionTransport(over AMDServiceConnection)
      └ AFCSession(AFC 包分帧 / roundTrip)
          └ AFCClient(高层文件 API)
HouseArrestClient / InstallationProxyClient(各自 plist-RPC 分帧)
DeviceManager(设备枚举 + 会话,串行 refreshQueue 收敛全部状态)
```

**并发**:`DeviceManager` 用一个串行 `refreshQueue` 收敛设备/会话状态,是全库最规范的并发模型。

> ⚠️ 但 `DeviceService` 门面的 `afcClient(for:)` 目前返回 `nil`(占位死壳),导致沙盒浏览的业务逻辑写在了 SwiftUI 视图里(`SandboxBrowserView` 等直接 new `AFCClient`);`DeviceManager` 是 552 行的全局单例。见 §7。

### 3.4 更新(`Core/Update`)

`UpdateService` 查 GitHub 最新 Release,`GitHubReleaseParser` 解析,`SemanticVersion` 比较版本,`AppInstaller` 下载并挂载 dmg。菜单/设置触发,详见 README。

### 3.5 共享层(`Core/Storage` / `Core/Logging` / `Core/UI`)

- **Storage**:`SettingsStore`(类型化 `SettingsKey` over `UserDefaults`)、`RecentFilesService`、`ArtifactStore`(+ `ResignArtifact`)。
- **Logging**:`LoggerService`(内存缓冲,capped 1000)+ `LogLevel`。
- **UI**:`LogPanelView`、`ProgressTimeline`、`FilePickerField`,以及**系统服务** `KeychainService`、`LaunchAtLogin`(严格说不算 UI,见 §7)。

---

## 4. 应用扩展与代码共享(QuickLook / Thumbnail)

仓库根有两个 appex target:`EasySignQuickLook/`(预览)与 `EasySignThumbnail/`(缩略图),给 IPA / mobileprovision 提供 Finder 预览与缩略图。

**代码共享方式**:预览/解析这坨共享代码已抽成**本地 Swift Package** `Packages/PreviewKit`(product/module `PreviewKit`),包含 `IPAPreviewService.swift`、`IPAPreviewHTMLRenderer.swift`、`MachOEntitlementsReader.swift`。主 App、`EasySignQuickLook`、`EasySignThumbnail` 三个 target 都以 SPM 依赖方式引用它(`import PreviewKit`),**共享由编译期强制**——取代了原先在 pbxproj 里逐文件挂 target membership 的脆弱做法。appex 自己的 UI 层(`PreviewViews.swift` 等)仍独立定义。

> 包只 import 系统框架(Foundation / Compression / CryptoKit / Security / os),对外 API(`IPAPreviewService`、`IPAPreviewInfo`、`IPAPreviewResult` 等模型类型)标 `public`;`IPAPreviewHTMLRenderer` / `MachOEntitlementsReader` 仅包内使用故保持 internal。新增依赖若不在包内会**编译期报错**,不再有"漏挂 appex Sources 静默失败"的隐患。

QuickLook 测试有坑:`qlmanage -t` 不走新管线且会挂死,只有 `/Applications` 里的副本会被真实派发 —— 见用户记忆 `quicklook-testing-gotchas`。

---

## 5. 构建与依赖

- **原始 pbxproj**(无 xcodegen、无 CocoaPods)。README 的编译命令为准;`CLAUDE.md` / `AGENTS.md` 里的 `pod install`、`xcodegen generate`、`project.yml`、`Views/`、`ResignService/` 均已过时。
- **依赖**:SPM `CryptoSwift`(仅主 target);**本地 SPM 包 `Packages/PreviewKit`**(主 App + 两个 appex 共享,见 §4);内嵌 `Vendor/OpenSSL/OpenSSL.xcframework`(OpenSSL 3.5.x);内嵌 zsign C++(`Vendor/ZSign/src`)经 `Core/Resigning/ZSign/` 的桥接(`ZSignBridge.mm`、`ZSignMachOInjector.cpp`,过 `EasySign-Bridging-Header.h`)。`MobileDevice.framework` 直接链接。
  - `Vendor/ZSign`(上游库)与 `Core/Resigning/ZSign`(本项目的桥/注入器)**不是重复**。

---

## 6. 测试

`Tests/` 是独立的 `swiftc @main` 可执行(**非 XCTest**),每个以 `print("ALL PASS")` 结尾,只测纯逻辑。约定见用户记忆 `testing-convention`:

```bash
# 例:排除 TransferService.swift 做单元级测试
swiftc -o /tmp/t EasySign/Core/Transfer/*.swift Tests/TransferLoopbackTests.swift && /tmp/t
```

新测试会在文件头注释里自带 `swiftc` 编译行(好习惯)。

> ⚠️ 现状:无聚合 runner、CI 不跑测试、依赖文件列表手工维护会漂移;`Tests/*.sh`(源码 grep 测试)引用的多是已删路径,是死重量,应删。

---

## 7. 已知架构债务与边界

宏观骨架(三层 + Tool 插件 + ServiceHub)是好的;债务集中在几个上帝对象、几个"做了一半"的重构、和跨子系统的重复实现。按性价比:

**A · 低风险清理**(本轮大多已完成,保留记录)
- ✅ 已删死代码:`ResignService/`(空目录)、`Core/Devices/FileTransfer.swift`、`TaskCenter` 的 `executeShell*`、12 个 stale `Tests/*.sh`。
- ✅ 已接上:`RecentFilesService`+`FilePickerField`(重签的 IPA/p12/描述文件选择框现在带最近记录 + 拖拽 + 清除)、`launchRestoresLastTool`(启动恢复上次工具现已生效)。
- ✅ 已更新:`CLAUDE.md` / `AGENTS.md`(过时内容已改准并指向本文档)。
- 待办:`ToolCategory.active/.advanced` 仍永远为空(只用了 `.frequent`),可删可启用。
- 已核实**非问题**:pbxproj 里 `IPAPreviewService`/`MachOEntitlementsReader` 出现"两次"是分属 QuickLook + Thumbnail 两个 appex target 的正确共享,不是重复;`libPods-iFocus.a`/`productName = iFocus` 是无害装饰性遗留(不在任何链接阶段,产物名以 `name`/`productReference` 为准)。

**B · 中杠杆**
- ✅ **统一日志(已完成)**:`LoggerService` 改为合并式 `@Published`(新增 `revision`,删掉 `LogPanelView` 的 0.5s 轮询定时器);重签并入 `LoggerService(tool:"resign")` + 结构化 `LogPanelView`,删除整套平行栈 `LegacyLogLevel/LoggerProtocol/ConsoleLogger/LegacyLogPanelView/ContentViewModel.logString`;Devices 26 处裸 `print` 并入 `LoggerService(tool:"devices")`(`DeviceManager.logger` 由 `ServiceHub.live()` 启动时注入)。唯一留置:`ResignTask` 的 `Dictionary.toPlist()` 兜底 catch 里 1 处 stdout print(泛型扩展无 logger 上下文)。
- ✅ **抽公共传输基础设施(已完成)**:HouseArrest / InstallationProxy / AFC 传输里重复的 secureStart 瞬时重试、send-all、recv-exact、瞬时错误码集合,归一到 `Core/Devices/ServiceConnectionIO`(各调用方仍抛自己的错误类型、errno 读取时机不变)。注:文件传输/进度的两套实现(互传 NWConnection 的 `FileTransferManager` vs 设备 AFC 的 `AFCClient`)是**不同传输协议**,未强行合并。
- ✅ **修 `DeviceService` 死壳门面(已完成)**:`afcClient(for:)` 返回真实现(+ 新增 `afcClient(forApp:)`),`SandboxBrowserView`/`FilePreviewView`/`DestinationPickerSheet` 的 AFC client 构造统一走门面;文件批处理循环抽到 `Features/Devices/SandboxFileOperations`(882→721 行)。
- ✅ **appex 共享改本地 SPM package(已完成)**:预览/解析三件套抽成 `Packages/PreviewKit`,三个 target 以 SPM 依赖引用(编译期强制),消除 §4 的构建脆弱点。对外类型改 `public`,手改 pbxproj 接线(`XCLocalSwiftPackageReference` + 三个 target 的 product 依赖)。注:1150 行的 `IPAPreviewService` god-file 现可在包内安全拆分(后续)。

**C · 大重构(等它真正付利息)**
- 引入 `ResignBackend` 协议(`func resign(...) throws -> URL`)+ `AppleResigner` / `ZSignResigner` 策略,把 `updateEntitlements` / `verifyZSignCandidate` 归位;统一 3 套 Mach-O 解析器与 3 套 IPA 解包。
- 继续拆 `TransferService`:重连协调器与执行门禁已抽出,后续可再分离连接生命周期、配对和文件传输编排。
- DI 收口:要么把 Devices 全量收进 `ServiceHub`(走 `hub.device`、强制 `requiredServices`),要么拆掉这套无人执行的清单仪式。
- 收敛持久化:多个功能绕开 `SettingsStore` 直写 `UserDefaults`;P12 密码目前明文存 `UserDefaults`,应挪进 `KeychainService`。

**分层违规**:`Core/UI/ProgressTimeline` 依赖 `Features/Resign` 的 `ResignStage`(Core → Features,反向);`KeychainService` / `LaunchAtLogin` 归在 `Core/UI` 但属系统服务。
