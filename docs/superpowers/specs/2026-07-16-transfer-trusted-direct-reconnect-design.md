# 互传可信直连回退自动重连设计

## 背景与根因

EasySign v1.3.1 的自动恢复只会拨号到当前 Bonjour 浏览结果中的匹配设备。自动目标必须同时满足：最后连接设备仍已配对、deviceId 单向拨号仲裁通过、网络路径可用，以及 `discoveredPeers` 中存在 deviceId 和 TLS 证书指纹都匹配的 endpoint。

办公电脑上的 Bonjour/mDNS 可能被系统裁剪或被网络策略禁用。此时用户仍可通过手动 IP 和端口完成首次配对，但连接因休眠断开后，`currentAutomaticTarget()` 永远返回 `nil`。网络路径虽然已恢复为 Wi-Fi，恢复协调器只能进入“等待设备重新出现或网络恢复”；用户点击“重试”之所以有效，是因为显式重试仍保留了手动 host/port。

仅把这份手动 host/port 直接交给自动重连并不完整：只有原主动连接方知道它，负责自动拨号的 deviceId 较小一方未必是原主动连接方；同时 `TransferServer` 重建时当前使用随机端口，旧端口可能失效。

## 目标

- 两台已配对设备通过手动 IP 建立连接后，即使 Bonjour 始终不可用，休眠或短暂断网恢复时也能自动重连。
- 自动恢复继续遵守 deviceId 较小的一端单向拨号，任何时刻最多只有一端主动连接。
- Bonjour 可用时优先使用其当前 endpoint；不可用时回退到已绑定 TLS 会话中学习到的可信直连地址。
- 监听器在同一 App 生命周期内因睡眠或网络变化重建时优先复用原端口。
- 自动直连继续使用已配对证书指纹 pinning，永远不使用或轮换配对码。
- 保持事件驱动的有限尝试窗口 `[0, 2, 5, 10]` 秒；耗尽后不保留定时器。
- 用户主动断开、停止服务、解除配对和旧 token/race 的现有语义不回归。

## 非目标

- 在休眠期间 DHCP 重新分配了对端 IP、且 Bonjour 也不可用时扫描或猜测新地址。
- 新建 UDP 广播、局域网端口扫描或绕过办公网络策略的发现协议。
- App 退出后自动恢复上次连接。`lastConnectedPeer` 继续保持 App 生命周期级；本次只保证进程仍在的休眠/断网恢复。
- 无限指数退避或后台轮询。
- 支持旧版本客户端完整参与可信地址交换；新消息保持可忽略的向后兼容，但两端都升级后才保证该能力。

## 发布交付

用户已明确授权在修复完成并验证无误后打 tag、推送远端用于发版。本改动按补丁版本 `v1.3.2` 交付：功能分支经评审后合并到 `main`，在主分支重新执行受影响测试和 Debug/Release 构建，再创建 annotated tag 并推送 `main` 与 tag。工程的 `MARKETING_VERSION` 不手改；现有 GitHub Actions release workflow 会从 `v1.3.2` 注入 `MARKETING_VERSION=1.3.2` 并构建发布产物。

## 方案

### 1. 可信直连地址

新增纯值类型 `TransferTrustedEndpoint`：

- `peer`：稳定的 `PeerRef(deviceId + fingerprint)`；
- `host`：从已就绪连接实际路径观察到的对端 IP；
- `port`：对端通过已绑定连接声明的监听端口；
- `reconnectEndpointKey`：包含来源、host 和 port，用于协调器 generation/token 校验。

`TransferService` 在主线程维护 App 生命周期级字典 `[PeerRef: TransferTrustedEndpoint]`。端点只有在连接已按 `PairedPeer` 绑定、消息来源仍是当前 `activeConn`、TLS 指纹与该配对记录一致时才能写入。解除对应配对或停止服务时删除；手动重新连接成功后由下一次交换覆盖。

不把端点作为新的信任根。即使旧 IP 后来属于另一台机器，自动连接仍以 `PeerRef.fingerprint` 创建 `.requirePinned` TLS 连接，证书不匹配会在绑定前失败。

### 2. 监听端口交换

在线路协议中增加控制帧：

```swift
case reconnectHint(port: UInt16)
```

连接完成配对或免码绑定后，每端向对方发送当前 `listenPort`。接收端从该 `TransferConnection` 的实际远端 endpoint 中提取 host，将它与消息中的监听端口组合，而不信任对端自行声明 host。

hint 的发送由三个确定事件驱动：

1. 绑定后先安装 `BoundInboundRouter`；如果此时 `listenPort` 已就绪，立即发送一次；
2. 每次 `TransferServer` 进入 `.ready` 并发布端口时，如果仍有 bound `activeConn`，发送当前端口。这同时覆盖“绑定时端口尚未 ready”和连接仍存活时 listener 改端口；
3. 绑定 500 毫秒后，如果仍是同一 bound connection 且当前端口有效，再有限补发一次，覆盖双方从配对 handler 切换到 bound handler 的竞态。

收到 hint 后立即保存，但不形成互相回送的循环。以上发送都由既有事件或一次性绑定补发触发，不运行周期定时器、不唤醒离线设备。

`reconnectHint` 只在 bound 数据路由中处理。配对期、未绑定连接、已被替换的旧连接或来源不匹配的迟到消息都不得更新端点。

### 3. 实际对端 host

`TransferConnection` 在 `.ready` 时从 `NWConnection.currentPath?.remoteEndpoint` 读取已解析的远端 endpoint，必要时回退到 `NWConnection.endpoint`。只接受可安全直连的 `.hostPort` 或 URL host；Bonjour service 名本身不能作为可信直连 host。

host 解析抽成纯函数并覆盖 IPv4、IPv6/URL 和不可解析 service endpoint 测试。服务层只在 host 有值且 port 非零时保存 hint。

### 4. 监听端口复用

`TransferServer` 在首次 `.ready` 后记住本次监听端口。后续 `.failed`/`.cancelled` 自愈或唤醒修复创建新 `NWListener` 时，优先使用 `NWListener(using:on:)` 绑定这个端口，而不是再次随机选择。

首次启动仍允许系统分配随机端口。本次不跨 App 启动持久化端口。首选端口失败策略必须按错误分类：

- `.failed(.posix(.EADDRINUSE))`：确认端口已被其他进程占用，清除本次首选端口，下一次立即使用系统随机端口；随机 listener `.ready` 后把新端口设为后续首选，并按“监听端口交换”规则通知仍存活的 bound connection。
- 其他错误（例如网络暂不可用）：保留首选端口，继续沿用现有 2 秒 listener 自愈，避免 Wi-Fi 尚未恢复时无故换端口。

如果端口被占用且原连接也已断开，对端无法提前获知随机新端口；在 Bonjour 不可用时本轮直连会有限失败并等待手动连接。这是端口冲突异常场景，不影响旧 listener 正常释放后的休眠恢复验收。

端口选择策略抽成小型纯状态，真实 Network.framework 测试验证指定端口可以被重新监听，避免只测试值类型而没有覆盖 `NWListener(using:on:)` 接线。

### 5. 自动目标选择

将自动目标从单一 `DiscoveredPeer` 扩展为：

```swift
enum TransferAutomaticTarget {
    case bonjour(DiscoveredPeer)
    case trusted(TransferTrustedEndpoint, peerName: String)
}
```

选择顺序：

1. 复用现有基础门禁：服务未停止、当前不忙、存在 `lastConnectedPeer`、配对仍存在、本机 deviceId 小于对端 deviceId；
2. `discoveredPeers` 中有 deviceId + fingerprint 匹配项时返回 `.bonjour`；
3. 否则有同一 `PeerRef` 的可信直连地址时返回 `.trusted`；
4. 都没有时返回 `nil` 并等待新事件。

两种目标都向协调器提供相同的 `PeerRef` 和稳定 endpoint key。每次实际拨号前继续重新解析最新快照并验证 token，避免旧地址回调替换新连接。

Bonjour 与可信直连之间发生切换时，若 endpoint key 真实改变，则把它视为一次新的外部 endpoint 事件：即使旧周期仍在活动，旧 token 也立即失效，新 generation 从 attempt 0 开始。此前 endpoint 的失败次数不计入新 endpoint。

同一 endpoint key 的规则分阶段处理：活动周期处于 dialing/waiting 时，重复发现、重复 hint、重复 `.satisfied` 或前台通知都不重置次数；周期已经耗尽并进入 `waitingForEvent` 后，新的系统唤醒、真实的网络 unavailable→satisfied 转换、App 重新激活或用户显式操作可以让同一 endpoint 开启新 generation。每一个由有效外部事件启动的稳定 endpoint 周期都严格最多执行 0/2/5/10 四次。

`.bonjour` 继续调用 `performOutbound(to:)`；`.trusted` 调用 `performOutbound(host:port:)`。两条自动路径都传入 `.automatic(token)` 和 `pairingCode: nil`，因此共享现有 TLS pinning、超时、有限重试与 stale callback 防护。

### 6. 恢复时序

成功绑定后：

1. 记录 `lastConnectedPeer`；
2. 安装 bound 消息路由；
3. 交换监听端口并学习可信地址；
4. 用当时可用的 Bonjour 或可信 endpoint key 更新协调器。

如果第 3 步时本机监听端口尚未 ready，第 2 节定义的 server `.ready` 事件会补发 hint；收到 hint 后，如果当前仍是同一 bound peer，则更新协调器保存的 endpoint key，但不会在已连接状态下拨号。

意外断线、系统唤醒、App 激活或网络路径恢复后：

1. 先修复 listener、广播和 discovery；
2. 若本机通过 deviceId 仲裁且 Bonjour 有目标，优先对 Bonjour endpoint 启动有限恢复；
3. Bonjour 无目标但存在可信地址时，对直连 host/port 启动同一个有限恢复周期；
4. 0/2/5/10 四次均失败后进入 `waitingForEvent`，不保留 timer；
5. 后续新的唤醒、真实网络恢复、Bonjour endpoint 变化、可信 endpoint 变化或用户操作才可开启新 generation；活动周期中的同 key 重复事件不重置预算，耗尽后的有效外部事件可以对同 key 开新周期。

恢复周期中 Bonjour 出现或消失、从而让实际目标在 Bonjour 与可信直连间切换时，按第 5 节的 endpoint 变化规则取消旧 token，并对新目标开启一次全新的有限 generation。

deviceId 较大的一端始终只修复监听并等待入站。因为绑定会让双方都学习对方监听地址，deviceId 较小的一端无论原会话是入站还是出站，都拥有拨号所需地址。

### 7. UI 与日志

- 有限恢复周期继续显示“连接断开，等待自动恢复…”或连接中状态。
- 没有任何可用 endpoint 时显示“等待设备重新出现或网络恢复”。
- 有可信 endpoint 但四次失败时显示“自动恢复暂未成功，等待网络变化或可手动重试”，避免把原因错误归为 Bonjour 未发现。
- 日志区分 `Bonjour` 与“可信直连”目标，并记录 host/port；不得记录配对码或证书材料。

## 安全与兼容性

- hint 只能改变“去哪里拨号”，不能改变“信任谁”；TLS 指纹 pinning 仍是免码重连的唯一信任判断。
- host 来自本机观察到的连接路径，消息只携带监听端口，降低对端伪造任意第三方地址的能力。
- 未知 WireMessage 在旧版本中会被忽略，因此不会破坏现有剪贴板/文件传输；但旧版本不回送 hint，无法保证无 Bonjour 自动恢复。
- 显式 `disconnect()` 的本机抑制、对端 `.bye`、清除配对以及 `stop()` 的行为维持不变，可信端点不能绕过这些门禁。

## 测试

### 纯逻辑与编解码

1. `reconnectHint` JSON round-trip、缺失/越界端口拒绝。
2. host 提取覆盖 `.hostPort`、URL 和 Bonjour service 不可直连。
3. 自动目标在 Bonjour 存在时优先 Bonjour；Bonjour 缺失时使用同一 `PeerRef` 的可信地址。
4. 指纹、deviceId、配对状态、busy、stop 或 deviceId 仲裁不匹配时，可信地址不能绕过门禁。
5. 可信地址 host/port 改变会产生新 endpoint key；相同地址不会重开活动周期。
6. bound hint 只接受当前活动连接，旧连接迟到消息不能覆盖地址。
7. 活动周期中同 key 的 server ready 补发、500ms 补发和重复恢复事件不重置预算；耗尽后新的唤醒/真实网络恢复可以让同 key 重开一次有限周期。
8. server `.ready` 与 500ms 补发都校验仍是同一 bound connection，旧连接补发不能污染新会话。

### Network.framework

9. `TransferConnection` 在真实 loopback 连接 ready 后可以取得远端 host。
10. `TransferServer` 重建 listener 时请求复用已知端口，并可在端口释放后重新监听同一端口。
11. 首选端口得到 `EADDRINUSE` 时只降级一次到随机端口，其他网络失败继续保留原首选端口。
12. 使用可信 host/port 与已配对指纹可免码连接；错误指纹被拒绝。

### 回归

13. 现有协调器严格保持 0/2/5/10 和耗尽后等待事件。
14. 自动直连失败会消费一次有限尝试，而不是退回手动 Retry 或无限轮询。
15. 用户主动断开、`.bye`、旧 token、入站抑制、配对修复、Bonjour 去重测试继续通过。
16. 完整 Debug/Release 构建通过。

## 验收标准

- 两台升级后的设备通过手动 IP/端口配对成功，即使“发现设备”列表始终为空，也会互相学习可信直连地址。
- 任意一台休眠导致连接中断后，在 IP 未变化的前提下，唤醒且网络路径恢复后无需点击“重试”即可恢复。
- 自动恢复仍只有 deviceId 较小的一端拨号，两端不会互相顶连接。
- 对端持续不可用时最多执行 0/2/5/10 四次，本轮结束后没有重试定时器。
- IP 改变或端口确实无法复用且 Bonjour 不可用时，有限尝试失败后允许用户手动连接；成功后刷新可信地址。
- 用户主动断开后，可信地址不会触发自动恢复。
