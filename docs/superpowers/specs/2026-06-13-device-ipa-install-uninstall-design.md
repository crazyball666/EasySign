# 设备页 IPA 安装 / 卸载设计

- 日期:2026-06-13
- 状态:设计已确认,实现中
- 范围:设备(Devices)页通用「安装 IPA」+「卸载用户 App」。不做重签→安装联动(以后另议)。

## 背景

设备子系统(MobileDevice.framework + 自研 AFC)已具备:连接/会话、`installation_proxy` 列表(`AMDeviceLookupApplications`)、AFC 文件读写(自研协议)、`HouseArrestClient`(`AMDeviceSecureStartService` → SSL → 长度前缀 plist 收发)。`DeviceService.installIPA()` 是预留桩,`InstallEvent` 进度流已就绪。新增装/卸**无需新 C 符号**(`AMDeviceSecureStartService`/`AMDServiceConnectionSend`/`Receive` 已声明)。

## 关键前提与已知限制

- **只能装设备「认」的 IPA**:签名/描述文件需覆盖该设备(开发证书 + 设备 UDID 在 profile;或企业签;或 App Store)。任意 IPA 装不进非越狱设备。对 EasySign(重签工具)正好顺。
- **真机 E2E 由用户做**:编解码 / 回复解释 / 编译可自动验证;真正装/卸到设备需插真机 + 一个该设备能装的 IPA,由用户手动验证。
- 卸载仅对**用户 App**开放入口(系统 App 会被 installation_proxy 拒)。

## 架构

照搬 `HouseArrestClient` 的「`AMDeviceSecureStartService` + 4 字节大端长度前缀 + XML plist 收发」范式,但 Install/Uninstall 是**流式**(一次请求,多条进度回复)。

### 纯逻辑(可独立 swiftc 测试)
- **`AMDPlistCodec.swift`**:`frame(dict) -> Data`(4 字节 BE 长度 + XML plist)、`bodyLength(prefix) -> Int?`。不引用任何 MobileDevice 符号,故可独立编译测试。
- **`InstallationProxyReply.swift`**:`enum InstallReply { progress(percent:Int?, status:String?); complete; failed(String) }` + `interpret(_ dict) -> InstallReply`。规则:有 `Error` → `.failed(Error[: ErrorDescription])`;`Status=="Complete"` → `.complete`;否则 `.progress(PercentComplete, Status)`。

### 集成(仅 App 内编译,真机 E2E)
- **`InstallationProxyClient.swift`**:
  - `open(deviceRef)`:`AMDeviceSecureStartService("com.apple.mobile.installation_proxy")`(transient 重试,复用 HouseArrest 同款退避)。
  - `send/recv`:用 `AMDPlistCodec` 帧 + `AMDServiceConnectionSend/Receive`(`readExact` 同 HouseArrest)。
  - `install(deviceRef:devicePackagePath:onProgress:)`:发 `{Command:Install, PackagePath, ClientOptions:{}}` → 循环 recv → `interpret` → 回调进度 / 完成 / 抛错。
  - `uninstall(deviceRef:bundleID:onProgress:)`:发 `{Command:Uninstall, ApplicationIdentifier}` → 同上。

### 安装流程(`DeviceService.installIPA` 实现桩)
1. `AFCClient(device:)` 媒体分区 → `createDirectory("PublicStaging")`(已存在忽略)→ `uploadFile(ipa → "PublicStaging/<name>.ipa", progress:)`。
2. `InstallationProxyClient.install(devicePackagePath:"PublicStaging/<name>.ipa")`。
3. 全程 `AsyncThrowingStream<InstallEvent>`:上传阶段 + 安装阶段两段进度;完成刷新 App 列表。
- 后台队列执行;deviceRef 经 `DeviceManager` 队列受限访问器获取(同 AppLister/HouseArrest)。

### 卸载
- `DeviceService.uninstallApp(bundleID:on:) -> AsyncThrowingStream<InstallEvent>` → `InstallationProxyClient.uninstall` → 完成刷新列表。

## UI

- `AppListView`(Apps 模式)顶部加「安装 IPA…」→ `NSOpenPanel`(限 `.ipa`)→ 进度(`InstallEvent` 流驱动进度条)。
- 每个**用户 App** 行加卸载(垃圾桶)→ 确认弹窗 → 卸载 → 刷新。
- 需设备已连接;未连接禁用入口。

## 测试

- 纯逻辑:`AMDPlistCodec.frame`(长度前缀正确、plist 可回解)、`bodyLength` 往返、`InstallReply.interpret`(progress / complete / error 三类样例回复)。
- 集成:**真机手动 E2E**(装入一个该设备能装的 IPA → 安装;选一个用户 App → 卸载)。编译 + 纯逻辑测试为自动门槛。

## 改动面

新增 `AMDPlistCodec.swift`、`InstallationProxyReply.swift`、`InstallationProxyClient.swift`;改 `DeviceService.swift`(实现 installIPA + 加 uninstall + 协议加方法);UI 改 `AppListView.swift` / `DeviceView.swift`。
