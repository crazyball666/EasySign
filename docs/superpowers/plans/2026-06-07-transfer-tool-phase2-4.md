# 互传(Transfer)Phase 2–4 实现计划

> **For agentic workers:** executed via subagent-driven-development on branch `feat/transfer-p234` (off Phase-1 `main`). Build gate: `xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build`. Pure logic / integration: standalone `swiftc -O -parse-as-library` `@main` executables in `Tests/` (see [[testing-convention]]).

**Goal:** 把互传从「手动 IP + 文本剪贴板」补全为完整工具:Bonjour 自动发现、菜单栏常驻、文件/图片传输、历史落盘、打磨(超时/重连/隐身/设置)。

**Builds on Phase 1:** identity + mutual-TLS-pinning + pairing(`PairingManager`)+ WS control channel(`TransferConnection`/`TransferServer`/`TransferClient`)+ `TransferService` 门面 + 文本剪贴板。复用全部既有安全通道,不改动加密/配对语义。

---

## 关键技术决策

1. **文件/图片走现有加密连接上的二进制 WebSocket 帧**,不另起 HTTP 服务。`NWProtocolWebSocket` 支持 `.binary` opcode。控制信令仍走 `.text`(JSON `WireMessage`),文件字节走 `.binary`。接收端按 opcode 区分。一次一个活跃连接、一次一个文件,简单可靠。
2. **菜单栏常驻** = `MenuBarExtra` 场景 + `NSApplicationDelegateAdaptor`(`applicationShouldTerminateAfterLastWindowClosed=false`),`TransferService` 活在 `ServiceHub`(App 生命周期)故关窗口后仍工作。
3. **开机自启** = `SMAppService.mainApp`(macOS 13+),默认关。
4. **收件箱** = `Application Support/EasySign/Transfer/inbox/`;历史索引 JSON 持久化,随启动加载。
5. **Bonjour** = `_easysign-transfer._tcp`,TXT 带 `deviceId`/`name`/`fingerprint`(供 UI 标注已配对、不含机密)。手动 IP 仍保留。隐身模式 = 不广播。

---

## Phase 2 — 发现 + 常驻

### Cluster P2-A:Bonjour 发现
**新增** `EasySign/Core/Transfer/PeerDiscovery.swift`:
- 广播:`TransferServer` 起监听后,设置 `listener.service = NWListener.Service(name: <deviceId>, type: "_easysign-transfer._tcp", txtRecord: <NWTXTRecord deviceId/name/fingerprint>)`。提供 `setAdvertising(_ on: Bool)`(隐身模式用)。
- 浏览:`NWBrowser(for: .bonjourWithTXTRecord(type: "_easysign-transfer._tcp", domain: nil), using: .tcp)`;结果映射为 `DiscoveredPeer { deviceId, name, fingerprint, endpoint: NWEndpoint }`;过滤掉自己(deviceId == 本机)。回调 `onPeersChanged([DiscoveredPeer])`。
**模型** 加 `DiscoveredPeer`(放 `TransferModels.swift`)。
**TransferService 集成**:`@Published var discoveredPeers: [DiscoveredPeer] = []`;`start()` 里启动 browse + 广播;`func connect(to peer: DiscoveredPeer, pairingCode: String?)` —— 新增 connect-by-endpoint 路径(复用现有 ready→pair/bind 逻辑,`TransferClient` 加 `connect(endpoint:pin:)` 重载)。
**TransferServer**:`start()` 接受可选 `advertise: (deviceId,name,fingerprint)`,起 service;加 `setAdvertising`。
**Info.plist**:加
```xml
<key>NSBonjourServices</key>
<array><string>_easysign-transfer._tcp</string></array>
```
验收:build green;真机两台能在列表里互相看到(手动 E2E)。

### Cluster P2-B:菜单栏常驻 + 开机自启
**改** `EasySign/App/EasySignApp.swift`:加 `@NSApplicationDelegateAdaptor`(AppDelegate 返回 `applicationShouldTerminateAfterLastWindowClosed=false`),加 `MenuBarExtra("互传", systemImage: "arrow.left.arrow.right") { TransferMenuBar(service:hub.transfer) }`。
**新增** `EasySign/App/TransferMenuBar.swift`:菜单栏内容 —— 连接状态、剪贴板同步开关、待显示配对码、最近 5 条收到记录、「打开主窗口」(用 `@Environment(\.openWindow)` 或 `NSApp.activate` + reopen)。
**新增** `EasySign/Core/UI/LaunchAtLogin.swift`:`SMAppService.mainApp` register/unregister + `isEnabled` 状态。
**改** `EasySign/App/SettingsView.swift`:加「开机自启」开关、设备名编辑、隐身模式开关(绑定 `SettingsStore` 新键)。
**SettingsStore**:加键 `transferLaunchAtLogin` / `transferStealthMode` / `transferDeviceName`(或复用 DeviceIdentityStore.deviceName)。
验收:关主窗口后 App 不退出、菜单栏图标在;开关开机自启生效。

---

## Phase 3 — 文件 + 图片 + 历史落盘

### Cluster P3-A:二进制通道 + 文件传输
**改** `EasySign/Core/Transfer/TransferServer.swift`(`TransferConnection`):
- 加 `func sendBinary(_ data: Data)`(`NWProtocolWebSocket.Metadata(opcode: .binary)`)。
- `receiveLoop` 读 `NWProtocolWebSocket.Metadata` 的 opcode:`.text` → 解码 `WireMessage` → 既有 onMessage(含缓冲);`.binary` → 新增 `var onBinary: ((Data)->Void)?`(同样 queue-confined 缓冲)。
**改** `WireMessage.swift`:加控制帧 `.fileOffer(id:name:size:)`、`.fileComplete(id:)`、`.fileAccept(id:)`(可选)、`.transferProgress(id:bytes:)`、`.clipboardImageOffer(id:size:hash:)`。扩展 Envelope 字段(`size:Int?`、`bytes:Int?` 等),decode 对应分支。补测试。
**新增** `EasySign/Core/Transfer/FileTransferManager.swift`:
- 发送:`send(url, over: TransferConnection, kind)` → 读文件分块(如 64KB)→ 发 `.fileOffer` → N 个 binary 帧 → `.fileComplete` → 进度回调。
- 接收:`onOffer` 开 inbox 临时文件 → 累积 binary 帧 → `onComplete` 落盘 + 回调 `TransferItem`。
- 进度/取消;一次一个文件(队列化)。
**新增** `EasySign/Core/Transfer/TransferPaths.swift`:inbox 目录(`Application Support/EasySign/Transfer/inbox`)。
**TransferService**:`func sendFile(_ url: URL)`;绑定 conn.onBinary/控制帧到 FileTransferManager;`@Published var activeTransfers: [FileProgress]`;已配对默认自动收;完成进 history。
**扩展 loopback 测试**:加一阶段 —— 配对后从 A 发一个临时文件,断言 B inbox 落盘且字节一致。
验收:loopback 文件阶段 ALL PASS;真机能拖文件发送。

### Cluster P3-B:图片剪贴板 + 历史落盘
**改** `EasySign/Core/Transfer/ClipboardMonitor.swift`:除文本外检测图片(`NSPasteboard` 读 PNG/TIFF → PNG Data),`onLocalImage((Data,hash)->Void)`;`applyIncomingImage(Data)`。回环防护同文本。
**图片传输**:复用二进制通道 —— `.clipboardImageOffer(id,size,hash)` + binary 帧 → 接收端组装 → 若同步开启写 `NSPasteboard`(PNG)+ 存 inbox + history(kind=.image)。
**新增** `EasySign/Core/Transfer/TransferHistoryStore.swift`:history 索引(JSON,含 kind/direction/time/preview/peerName/localPath)持久化到 Application Support;`load()`/`append()`/`clear()`;容量上限 + 按天清理接口。`TransferService.history` 由它支撑(启动 load)。`TransferItem` 加可选 `localURL: URL?`。
验收:build green;图片复制能同步;重启后历史还在。

### Cluster P3-C:UI 升级
**改** `EasySign/Features/Transfer/TransferToolView.swift`:
- 发现列表卡片(`discoveredPeers`,标注已配对/未配对,点连接)。
- 拖拽发送区(`.onDrop` 收文件 URL → `service.sendFile`)+「发送文件…」按钮(NSOpenPanel)。
- 进行中传输进度(`activeTransfers`)。
- 历史项支持文件/图片:`.file`→打开/Finder 显示;`.image`→缩略图 + 复制/打开;`.text`→复制(已有)。
验收:build green;面板可用。

---

## Phase 4 — 打磨

### Cluster P4:打磨
- **连接超时**:`connect`/`connect(to:)` 起 N 秒(如 12s)计时器,未 `.ready` → `.failed("连接超时")` + cancel。处理 `.waiting` 状态(显示「网络等待…」而非卡「连接中」)。
- **断线重连**:已配对的活跃连接断开后,对该 peer 做指数退避重连(上限);状态显示「重连中」。
- **隐身模式**:`SettingsStore.transferStealthMode` → `PeerDiscovery.setAdvertising(false)`。
- **身份生成移出主线程**:`TransferService.start()` 的 `identity()` 首次生成放后台队列,完成后回主线程起监听(避免首启卡顿)。
- **历史清理**:按 `SettingsStore` 保留天数删除 inbox 旧文件 + 历史项(启动时跑一次)。
- **设置补全**:清空已配对设备、清空历史、保留天数。
- **杂项**:Phase 1 review 遗留的 minor(`.waiting` 处理、`WireMessage.ack` 落地或删除)。
验收:build green;真机超时/重连/隐身/自启/清理可用。

---

## 测试与验收策略
- 纯逻辑(WireMessage 新帧、FileTransferManager 分块/重组、历史存储编解码)→ 独立 swiftc `@main` 测试。
- 端到端(配对→文件→图片)→ 扩展 `Tests/TransferLoopbackTests.swift` 的真实栈回环测试。
- 最终两台 Mac 手动 E2E(用户验收):发现、配对、文本/文件/图片互传、菜单栏常驻、自启、隐身、重连。

## 不在本计划内(明确)
- 多设备(N≥3)组网;云中转/公网穿透;非 Mac 端实现(协议已中立留口)。
