# 互传(Transfer)工具设计

- 日期:2026-06-07
- 代号:`Transfer`(中文名「互传」)
- 状态:设计已确认,待编写实现计划

## 1. 背景与目标

用户有两台办公 Mac,其中一台因策略限制不能用 AirDrop,导致在两台机器间传文本、文件、剪贴板图片很麻烦,需要频繁来回切换。

目标:在 EasySign 工具集里新增一个「互传」工具,让两台 Mac 在同一局域网内**直连**(不经任何云/中转),便捷、安全地互传:

- **共享剪贴板**:开关控制,开启后一台复制文本/图片,另一台自动同步,可直接 `Cmd+V` 粘贴。双向。
- **手动发送文件**:拖拽 / 菜单栏 / 发送当前选中,推到另一台。
- **双向传输历史(收件箱)**:收发记录集中展示,每条可「复制到剪贴板 / Finder 显示 / 打开 / 重发」。

### 已确认的约束与决策

| 维度 | 决策 |
|---|---|
| 平台 | 两台都是 Mac;协议保持中立(HTTP/WebSocket),为未来网页端/Windows 端留口 |
| 网络 | 同一局域网,能直连;AirDrop 是被策略禁用,普通 TCP 不受影响 → 纯本地直连,无需云 |
| 交互 | 共享剪贴板(自动双向) + 手动发文件 + 双向历史面板 |
| 安全 | 配对码 + TLS 加密传输;配对码绑定证书指纹防中间人 |
| 运行形态 | 菜单栏常驻后台,粘贴板同步/收文件不依赖主窗口;可选开机自启 |
| 收文件默认 | 已配对设备 = 默认自动接收(落地到历史,不每次弹确认);可在设置改为「每次询问」 |
| 剪贴板安全默认 | 默认跳过被标记为机密/临时的剪贴内容(`org.nspasteboard.ConcealedType` / `TransientType`) |

### 非目标(YAGNI)

- 不做云中转 / 公网穿透(同网直连已满足)。
- 不做 N≥3 设备的复杂组网;按「一组已配对设备」设计,优化两台机器场景。
- 不引入第三方 PAKE 库;用「配对码绑证书指纹」的轻量防 MITM 方案。
- 不防御「已配对机器本身被攻陷」。

### 关键技术前提

- 主 App **未开启沙盒**(`EasySign.entitlements` 为空 `<dict/>`)→ 监听端口、读写文件、本地网络均无沙盒限制,无需 network.server/client 权限和 security-scoped bookmark。
- 入口为 SwiftUI `WindowGroup` + `Settings`;新增 `MenuBarExtra` 场景 + AppDelegate 实现常驻。
- macOS Sequoia 本地网络隐私:即便非沙盒也需在 `Info.plist` 加 `NSLocalNetworkUsageDescription` 与 `NSBonjourServices`。

## 2. 传输方案选型

选定**方案 A:内嵌 HTTP/WebSocket(基于 Network.framework)**。

| | A:内嵌 HTTP/WS(选定) | B:自定义 TCP 二进制 | C:MultipeerConnectivity |
|---|---|---|---|
| 底层 | `NWListener` 跑 HTTP + WebSocket | 裸 TCP + 自定义帧 | Apple MPC |
| 发现 | Bonjour + 手动 IP 兜底 | 同左 | 框架内置 |
| 加密 | 自签 TLS,配对码 pin 证书 | 需自行包 TLS | 框架内置 |
| 未来跨平台 | ✅ 网页/Windows 直接讲 HTTP/WS | ❌ 私有协议 | ❌ 仅 Apple 生态 |
| 公司网风险 | ✅ 普通 TCP,与 AirDrop 无关 | ✅ 同 A | ❌ 走 AWDL,与 AirDrop 同源,极可能一并被禁 |
| 依赖 | 0(纯系统框架) | 0 | 0 |

排除 C 的核心理由:MPC 底层是 AWDL,与被禁的 AirDrop 同一套技术,极可能被同一条策略一起挡掉 —— 而本工具的全部意义就是绕开该限制。

## 3. 架构与分层

沿用现有 App / Features / Core 三层,依赖只向下流。

```
App/                          ← 应用级外壳(最上层)
  TransferMenuBar.swift        菜单栏常驻:同步开关、配对/连接状态、最近收到、快捷发送
  EasySignApp.swift            +MenuBarExtra 场景;+AppDelegate 让关窗口后不退出

Features/Transfer/            ← 窗口内 Tool(中间层,沿用 ResignTool 模式)
  TransferTool.swift           : Tool,注册进 ToolRegistry,requiredServices=[.transfer,.logger]
  TransferToolView.swift       面板:配对/连接状态 + 同步开关 + 拖拽发送区 + 双向历史列表 + 每条操作

Core/Transfer/                ← 引擎(最底层,无 UI,不依赖上层)
  TransferService.swift        门面 / ObservableObject,注入 ServiceHub.transfer,持有 @Published 状态
  TransferServer.swift         NWListener(TLS):HTTP 收文件 + WebSocket 收信令/剪贴板
  TransferClient.swift         NWConnection(TLS):向对端发剪贴板 / 推文件
  PeerDiscovery.swift          Bonjour 广播+浏览 `_easysign-transfer._tcp` + 手动 IP 兜底
  PairingManager.swift         配对码握手 → 共享密钥/指纹绑定 → 存储;TLS 指纹 pin
  ClipboardMonitor.swift       轮询 NSPasteboard.changeCount,抽取/应用剪贴内容
  TransferHistoryStore.swift   收到内容落地 Application Support + 索引(仿 ArtifactStore)
  DeviceIdentity.swift         自签身份生成/加载(私钥进 Keychain)
  Models:
    Peer            发现到的对端(deviceId、name、host、port、fingerprint、platform)
    PairedPeer      已配对对端(deviceId、name、pinned fingerprint)
    TransferItem    一条收发记录(id、kind、direction、time、size、preview、localURL?、status)
    TransferKind    .text / .image / .file
    WireMessage     WS 消息编解码(hello/clipboard/file-offer/progress/ack)
```

### 接线点(与现有代码一致)

- `Core/Toolkit/ServiceKey.swift`:`enum ServiceKey` 加 `case transfer`
- `Core/Toolkit/ServiceHub.swift`:加 `let transfer: TransferService`,`live()` 构造、`subscript` 返回
- `Core/Toolkit/ToolRegistry.swift`:`allTools` 加 `TransferTool()`
- `EasySign/Info.plist`:加 `NSLocalNetworkUsageDescription` + `NSBonjourServices`(列 `_easysign-transfer._tcp`)
- 复用 `Core/UI/KeychainService.swift` 存设备私钥

### 生命周期要点

`TransferService` 活在 `ServiceHub`(App 生命周期),剪贴板同步/收文件不依赖主窗口开关。菜单栏常驻与「关窗继续后台跑」由 `MenuBarExtra` + AppDelegate(`applicationShouldTerminateAfterLastWindowClosed = false`)实现。`Core/Transfer` 不依赖任何上层,未来可整体抽出复用。

## 4. 数据流与协议

### 会话模型

两端配对后各自既是 server(`NWListener`)又是 client。日常保持一条 **WebSocket 控制长连接**(信令 + 剪贴板),**大文件走独立 HTTP 连接**,不堵塞控制通道。

### 流程 1:发现 + 连接

```
A 启动 → Bonjour 广播 _easysign-transfer._tcp(TXT: deviceId / name / fingerprint / 版本 / platform)
A 的 NWBrowser 发现 B → 菜单栏/面板显示「B 可连接」
点连接 → 已配对(本地有 B 的 pinned 指纹)则直接建 TLS+WS;否则进配对流程
兜底:Bonjour 被公司网挡 → 手动输入 B 的 IP:端口
自连过滤:忽略 deviceId == 自己 的 Bonjour 广播
```

### 流程 2:配对(仅首次)

```
A 发起 → B 弹出 6 位配对码 → A 输入 → 双方按 §5 握手认证
成功 → 各自把对方证书指纹存为 PairedPeer → 以后免码自动连
```

### 流程 3:共享剪贴板(开关开启时)

```
ClipboardMonitor 轮询 NSPasteboard.changeCount(~0.4s)
变化 → 跳过机密/临时标记 → 抽取(文本 / 图片PNG / 文件URL列表)
     → 经 WS 发 {type:"clipboard", kind, payload}(文本/小图内联;大图走文件通道)
对端收到 → 写入历史 + 若同步开启则写 NSPasteboard(可直接 Cmd+V)
回环防护:内容哈希 + 来源标记 + 记住自己写入时的 changeCount;快速变化做防抖
并发复制:最新者胜,但两条都进历史,不丢内容
```

### 流程 4:文件发送(手动)

```
拖文件到面板 / 菜单栏「发送文件…」/ 发送当前选中
→ WS 发 {type:"file-offer", id, name, size} → 对端(已配对,默认自动接收)
→ 发送端 HTTP POST /file/{id} 流式上传 → 对端流式落盘到 inbox
→ 进度经 WS 回传 → 完成后历史出现一条,可「打开 / Finder 显示 / 复制路径」
```

### 协议面(中立,网页端可直接讲)

- **WebSocket** `wss://host:port/ws`:JSON 消息
  - `hello`:握手(deviceId、name、protocol 版本)
  - `clipboard`:`{kind: text|image, payload | fileRef}`
  - `file-offer`:`{id, name, size}`
  - `progress`:`{id, bytes}`
  - `ack`:`{id}`
- **HTTP** `POST /file/{id}`:分块流式上传,body 为文件字节
- 全部跑在自签 TLS 之上
- 文本 >256KB 或图片自动改走文件通道,不内联塞 WS

## 5. 配对与加密

### 设备身份(首次启动生成一次)

- 每台生成自签 P-256 身份证书(SecIdentity);私钥存 Keychain(复用 `KeychainService`)。
- 证书指纹(DER 的 SHA-256)= 设备唯一身份;另有稳定 `deviceId`(UUID) + 可改设备名。

### 传输加密

`NWProtocolTLS` 加载自签身份;关闭默认链校验,装 `sec_protocol_options_set_verify_block`:**只放行 pin 住的指纹**。已配对 = 指纹匹配才放行 → 天然挡陌生机器 + 防窃听。

### 配对码防中间人(核心)

6 位码不直接当密码,而是**把码与「双方实际看到的证书指纹」绑定**:

```
A、B 各自计算 HMAC(配对码, 排序后的[A指纹, B指纹] ‖ 双方随机数),交换并互验
```

- 中间人对 A 出示证书 M、对 B 出示证书 M′ → 两条腿的指纹集合不同 → HMAC 必然不匹配 → 配对失败。即把「6 位码」绑死到真实证书上,挡住 MITM,无需 PAKE 库。
- 6 位码 ≈ 20 bit,在线攻击者每次连接仅一次猜测机会;**猜错即重置换码 + 限流**(连错 3 次冷却),对两台机器的个人场景足够。
- 成功后双方互存对方指纹为 `PairedPeer`(指纹为公开信息,存 app 存储即可;仅私钥进 Keychain)。

### 剪贴板安全默认

默认跳过被标记为机密/临时的剪贴内容(`org.nspasteboard.ConcealedType` / `org.nspasteboard.TransientType`,密码管理器复制时会打此标),零成本避免把密码同步过去。可在设置关闭。

### 安全边界

- **受信任**:两台已配对机器。**不受信任**:网内其他所有机器。
- **防护**:强制配对 + 指纹 pin + TLS 加密 + 配对码绑证书防 MITM + 仅已配对自动收 + 配对限流。
- **不防**:已配对机器本身被攻陷;公司网络看到「存在此设备 + Bonjour 广播的设备名」。
- **可选隐身模式**:不广播 Bonjour、仅手动连,减少 LAN 上的可见性。

## 6. 错误处理与边界

| 情况 | 处理 |
|---|---|
| 对端离线 / WS 断开 | 指数退避自动重连;状态显示(已连接/连接中/离线)。剪贴板不排队(最新覆盖);传输中文件标记失败,可重发 |
| 配对码输错 | 失败 → 重置换新码 + 限流(连错 3 次冷却) |
| Bonjour 被挡 | 自动降级手动输 IP:端口 + 提示 |
| 本地网络权限被拒(Sequoia) | 检测 → 引导去「系统设置 > 隐私 > 本地网络」 |
| 端口冲突 | `NWListener` 用系统分配临时端口,实际端口经 Bonjour TXT 公布 / 手动模式显示 |
| 大文件 | 流式落盘不进内存,显示进度可取消;磁盘满 → 报错并清理半成品 |
| 超大/超长剪贴内容 | 文本 >256KB 或图片自动改走文件通道 |
| 剪贴板回环 | 内容哈希 + 来源标记 + 记住自身写入 changeCount;快速变化防抖 |
| 双方同时复制 | 最新者胜,两条都进历史 |
| 重启 App | 从 Keychain 恢复身份 + 已配对列表,重新广播 |
| 历史膨胀 | 历史条数上限;收到文件存 `Application Support/Transfer/inbox`,可设置自动清理 N 天前 |
| 陌生机器入站 | TLS 指纹 pin 不过 → 直接拒连 |

## 7. 测试策略

- **单元(无需网络,价值最高)**:配对 HMAC/防 MITM 逻辑(给定证书+码 → 验匹配/不匹配)、剪贴板抽取(pasteboard→TransferItem)、回环哈希、历史存储、`WireMessage` 编解码。
- **集成(进程内回环)**:`127.0.0.1` 起两个实例配对,发文本断言收到、发文件断言字节一致、pin 不符断言拒连。覆盖核心「安全通道」。
- **手动 E2E**:真机两台 Mac 在公司网跑通(最终验收)。

## 8. MVP 分期(每期可独立用、可验收)

- **Phase 1 — 安全通道地基**:设备身份 + TLS 指纹 pin + 配对码握手 + WS 控制通道 + 手动 IP 连接 + 文本剪贴板同步 + 窗口内历史列表。两台 Mac 端到端验证,打通最难的「安全直连」。
- **Phase 2 — 发现 + 常驻**:Bonjour 自动发现 + 菜单栏常驻(`MenuBarExtra` + 关窗不退) + 菜单栏同步开关 + 开机自启。
- **Phase 3 — 文件与图片**:文件发送(HTTP 上传、拖拽、进度、自动接收) + 图片剪贴板同步。
- **Phase 4 — 打磨**:断线重连退避、隐身模式、机密内容跳过、历史自动清理、设置项。
