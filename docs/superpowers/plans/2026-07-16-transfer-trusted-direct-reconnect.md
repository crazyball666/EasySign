# Transfer Trusted Direct Reconnect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让通过手动 IP 配对的设备在 Bonjour 永久不可用时，仍能在休眠或网络恢复后使用 TLS 指纹固定的可信直连地址自动重连。

**Architecture:** 已绑定连接互相发送监听端口，接收端把端口与本机观察到的远端 IP 组合成 App 生命周期级可信 endpoint。自动目标优先当前 Bonjour，缺失时回退可信 endpoint；`TransferServer` 自愈时复用原端口，现有单向拨号仲裁和 0/2/5/10 有限恢复状态机保持不变。

**Tech Stack:** Swift 6、Network.framework、Security、WebSocket-over-TLS、GCD、独立 `swiftc @main` 测试、Xcode 16 synchronized groups。

---

## 文件职责

- 新建 `EasySign/Core/Transfer/TransferTrustedEndpoint.swift`：可信 host/port、Bonjour/直连统一自动目标、NWEndpoint host 提取。
- 新建 `EasySign/Core/Transfer/TransferReconnectHintPolicy.swift`：把 bound source、PeerRef、remote host 和 hint port 收敛为可保存 endpoint 的纯门禁。
- 新建 `EasySign/Core/Transfer/TransferListenerPortPolicy.swift`：queue 外可单测的 preferred-port 选择、ready 更新和失败降级规则。
- 修改 `EasySign/Core/Transfer/TransferAutoReconnect.swift`：保留基础门禁与 deviceId 仲裁，Bonjour 缺失时选择可信 endpoint。
- 修改 `EasySign/Core/Transfer/WireMessage.swift`：新增 `reconnectHint(port:)` 控制帧及严格编解码。
- 修改 `EasySign/Core/Transfer/TransferServer.swift`：连接 ready 时捕获远端 host；listener 重建优先复用端口，只有 `EADDRINUSE` 才降级随机端口。
- 修改 `EasySign/Core/Transfer/TransferService.swift`：维护可信 endpoint、发送/接收 hint、选择并执行直连自动目标、清理旧 endpoint。
- 修改 `Tests/TransferAutoReconnectTests.swift`：覆盖 Bonjour 优先、可信回退和所有仲裁门禁。
- 新建 `Tests/TransferTrustedEndpointTests.swift`：覆盖 endpoint key、host 提取和 hint 可信门禁。
- 修改 `Tests/WireMessageTests.swift`：覆盖 hint round-trip 与非法 port。
- 新建 `Tests/TransferServerPortReuseTests.swift`：覆盖指定端口监听、释放后复用及端口占用判定。
- 修改 `Tests/TransferLoopbackTests.swift`：真实 TLS loopback 验证两端可观察远端 host、hint 传输和 pinned 直连不回归。
- 修改 `Tests/TransferReconnectExecutionPolicyTests.swift`：覆盖旧 bound connection 的 hint/补发必须被忽略。
- 修改 `CLAUDE.md`、`docs/architecture.md`：更新“手动 IP 只能显式 Retry”的旧不变量。

## Task 1: 用纯逻辑固定可信目标选择

**Files:**

- Create: `EasySign/Core/Transfer/TransferTrustedEndpoint.swift`
- Modify: `EasySign/Core/Transfer/TransferAutoReconnect.swift`
- Modify: `Tests/TransferAutoReconnectTests.swift`
- Create: `Tests/TransferTrustedEndpointTests.swift`

- [ ] **Step 1: 写 Bonjour 优先与可信回退失败测试**

测试至少构造以下行为：

```swift
let peer = TransferAutoReconnect.PeerRef(deviceId: "B", fingerprint: "fp-B")
let trusted = TransferTrustedEndpoint(peer: peer, host: "10.0.0.8", port: 54321)

let fallback = TransferAutoReconnect.target(
    busy: false,
    userStopped: false,
    selfDeviceId: "A",
    last: peer,
    discovered: [],
    trusted: [peer: trusted],
    pairedPeers: [PairedPeer(deviceId: "B", name: "Mac B", fingerprint: "fp-B")]
)
expect(fallback?.reconnectEndpointKey == trusted.reconnectEndpointKey,
       "Bonjour 缺失时应回退可信地址")
```

同一测试必须证明：Bonjour 匹配项优先；busy、userStopped、未配对、错误 fingerprint、错误 deviceId、本机 deviceId 较大时均为 `nil`；可信地址不能绕过原仲裁。

- [ ] **Step 2: 运行测试并确认 RED**

Run:

```bash
swiftc -swift-version 5 -module-cache-path /tmp/easysign-swift-module-cache \
  EasySign/Core/Transfer/TransferModels.swift \
  EasySign/Core/Transfer/TransferAutoReconnect.swift \
  Tests/TransferAutoReconnectTests.swift \
  -o /tmp/transfer-auto && /tmp/transfer-auto
```

Expected: compile failure mentioning missing `TransferTrustedEndpoint` or new `target` signature.

- [ ] **Step 3: 实现最小可信 endpoint 与统一目标**

新增接口形状：

```swift
struct TransferTrustedEndpoint: Equatable, Sendable {
    let peer: TransferAutoReconnect.PeerRef
    let host: String
    let port: UInt16
    var reconnectEndpointKey: String { "trusted:\(peer.deviceId):\(host):\(port)" }
}

enum TransferAutomaticTarget {
    case bonjour(DiscoveredPeer)
    case trusted(TransferTrustedEndpoint, peerName: String)

    var peerRef: TransferAutoReconnect.PeerRef { /* exhaustive switch */ }
    var reconnectEndpointKey: String { /* exhaustive switch */ }
    var displayName: String { /* exhaustive switch */ }
}
```

`TransferAutoReconnect.target` 先执行所有现有基础门禁和 `selfDeviceId < last.deviceId`，再先找匹配 Bonjour，最后找同一 `PeerRef` 的可信 endpoint。不要在目标枚举里加入定时或网络副作用。

- [ ] **Step 4: 运行目标测试并确认 GREEN**

Run the Step 2 command plus `EasySign/Core/Transfer/TransferTrustedEndpoint.swift`.

Expected: `ALL PASS`.

- [ ] **Step 5: 写并运行 endpoint key 纯测试**

`Tests/TransferTrustedEndpointTests.swift` 只验证相同 peer+host+port key 稳定、host/port 变化 key 改变。所有依赖 host 提取 API 的测试在 Task 2 才新增，确保本 Task 提交时保持 GREEN。

- [ ] **Step 6: 提交纯目标策略**

```bash
git add EasySign/Core/Transfer/TransferTrustedEndpoint.swift EasySign/Core/Transfer/TransferAutoReconnect.swift Tests/TransferAutoReconnectTests.swift Tests/TransferTrustedEndpointTests.swift
git commit -m "feat(transfer): add trusted reconnect targets"
```

## Task 2: 增加安全的监听端口 hint 与远端 host 捕获

**Files:**

- Modify: `EasySign/Core/Transfer/WireMessage.swift`
- Modify: `EasySign/Core/Transfer/TransferServer.swift`
- Modify: `EasySign/Core/Transfer/TransferTrustedEndpoint.swift`
- Create: `EasySign/Core/Transfer/TransferReconnectHintPolicy.swift`
- Modify: `Tests/WireMessageTests.swift`
- Modify: `Tests/TransferTrustedEndpointTests.swift`
- Modify: `Tests/TransferReconnectExecutionPolicyTests.swift`

- [ ] **Step 1: 写 WireMessage hint 失败测试**

```swift
let hint = WireMessage.reconnectHint(port: 54321)
expect(try WireMessage.decode(hint.encoded()) == hint, "reconnectHint round-trip")
let missing = Data(#"{"type":"reconnectHint"}"#.utf8)
expectThrows { try WireMessage.decode(missing) }
let overflow = Data(#"{"type":"reconnectHint","port":65536}"#.utf8)
expectThrows { try WireMessage.decode(overflow) }
```

- [ ] **Step 2: 运行 WireMessage 测试并确认 RED**

```bash
swiftc -swift-version 5 -module-cache-path /tmp/easysign-swift-module-cache \
  EasySign/Core/Transfer/WireMessage.swift Tests/WireMessageTests.swift \
  -o /tmp/wire-message && /tmp/wire-message
```

Expected: compile failure because `.reconnectHint` does not exist.

- [ ] **Step 3: 实现严格 hint 编解码**

在 `WireMessage` 与 `Envelope` 增加 `UInt16? port`。decode 必须要求存在有效端口；JSON 的负数或大于 65535 的值必须解码失败，不做截断。

- [ ] **Step 4: 写远端 host 与 stale hint 失败测试**

覆盖：

```swift
expect(TransferTrustedEndpoint.host(from: .hostPort(host: "10.0.0.8", port: 5000)) == "10.0.0.8", "IPv4")
expect(TransferTrustedEndpoint.host(from: .url(URL(string: "ws://10.0.0.9:5000/transfer")!)) == "10.0.0.9", "URL host")
expect(TransferTrustedEndpoint.host(from: .service(name: "B", type: "_x._tcp", domain: "local.", interface: nil)) == nil, "Bonjour service 不能作为直连 IP")
expect(TransferReconnectHintPolicy.endpoint(peer: peer, sourceIsActive: false, remoteHost: "10.0.0.8", port: 5000) == nil, "旧连接 hint 必须忽略")
```

- [ ] **Step 5: 在 `.ready` 捕获实际远端 host 并实现纯门禁**

`TransferConnection` 增加线程安全只读 `remoteHost`。在 `.ready` 且设置 fingerprint 之前/同时，从 `nw.currentPath?.remoteEndpoint ?? nw.endpoint` 调用 `TransferTrustedEndpoint.host(from:)`，用锁发布结果。

`TransferReconnectHintPolicy.endpoint(...)` 只有 `sourceIsActive == true`、host 非空、port 有效时才返回与指定 `PeerRef` 绑定的 endpoint。它不能接收或修改配对记录。

- [ ] **Step 6: 运行 Task 2 三组测试并确认 GREEN**

Expected: `WireMessageTests`、`TransferTrustedEndpointTests`、`TransferReconnectExecutionPolicyTests` 均输出 `ALL PASS`。

- [ ] **Step 7: 提交协议与连接元数据**

```bash
git add EasySign/Core/Transfer/WireMessage.swift EasySign/Core/Transfer/TransferServer.swift EasySign/Core/Transfer/TransferTrustedEndpoint.swift EasySign/Core/Transfer/TransferReconnectHintPolicy.swift Tests/WireMessageTests.swift Tests/TransferTrustedEndpointTests.swift Tests/TransferReconnectExecutionPolicyTests.swift
git commit -m "feat(transfer): exchange trusted reconnect hints"
```

## Task 3: 让 listener 自愈复用原端口

**Files:**

- Modify: `EasySign/Core/Transfer/TransferServer.swift`
- Create: `EasySign/Core/Transfer/TransferListenerPortPolicy.swift`
- Create: `Tests/TransferServerPortReuseTests.swift`

- [ ] **Step 1: 写端口选择策略与真实复用失败测试**

先对纯 `TransferListenerPortPolicy` 写确定性状态测试，再写实际 listener 复用测试。必须覆盖：

- 首次没有 preferred port 时由系统随机分配；
- `.ready` 后保存实际 port；
- 重新创建 listener 时调用 `NWListener(using:on:)` 请求原 port；
- 释放旧 listener 后新 server 可以监听同一 port；
- `NWError.posix(.EADDRINUSE)` 清除 preferred 并请求随机端口；
- 其他错误保留 preferred。

纯策略接口形状：

```swift
struct TransferListenerPortPolicy {
    enum FailureKind { case addressInUse, other }
    enum BindingChoice: Equatable { case random, preferred(UInt16) }
    private(set) var preferredPort: UInt16?

    mutating func listenerReady(port: UInt16)
    mutating func listenerFailed(requestedPort: UInt16?, kind: FailureKind) -> BindingChoice
    var nextBinding: BindingChoice { get }
    static func failureKind(for error: NWError) -> FailureKind
}
```

这样 `EADDRINUSE` 与普通网络失败不依赖真实系统时序即可覆盖；真实测试只负责证明指定端口能够监听和释放后复用。

- [ ] **Step 2: 运行端口测试并确认 RED**

使用与 `TransferLoopbackTests` 相同的 DeviceIdentity/TransferTLS/TransferServer 依赖编译：

```bash
swiftc -swift-version 5 -module-cache-path /tmp/easysign-swift-module-cache \
  EasySign/Core/Transfer/CertFingerprint.swift \
  EasySign/Core/Transfer/DeviceIdentity.swift \
  EasySign/Core/Transfer/PairingCrypto.swift \
  EasySign/Core/Transfer/PeerDiscovery.swift \
  EasySign/Core/Transfer/TransferTLS.swift \
  EasySign/Core/Transfer/TransferListenerPortPolicy.swift \
  EasySign/Core/Transfer/TransferTrustedEndpoint.swift \
  EasySign/Core/Transfer/WireMessage.swift \
  EasySign/Core/Transfer/TransferServer.swift \
  Tests/TransferServerPortReuseTests.swift \
  -o /tmp/transfer-port-reuse && /tmp/transfer-port-reuse
```

Expected: compile/assertion failure because `TransferListenerPortPolicy` and preferred-port listener API are absent.

- [ ] **Step 3: 实现 preferred port 状态机**

`TransferServer` queue-confined 状态持有 `TransferListenerPortPolicy`。`makeListener()` 从 `nextBinding` 捕获本次 `requestedPort`：有值时使用 `NWListener(using:on:)`，无值时使用原随机构造。`.ready` 把实际端口交给 `listenerReady(port:)`。

`.failed(let error)` 使用 `failureKind(for:)` 和 `listenerFailed(...)` 决定下一次绑定。只有 requested preferred + `EADDRINUSE` 才立即随机重建；其他错误保留 preferred 并沿用 2 秒自愈。旧 listener identity guard 与 `stopped` guard 必须保留。

- [ ] **Step 4: 运行端口测试并确认 GREEN**

Expected: `ALL PASS`，并确认进程退出无残留 listener。

- [ ] **Step 5: 回归真实断连检测**

Compile/run `Tests/TransferDisconnectDetectionTests.swift` with the same transport dependencies.

Expected: `ALL PASS`.

- [ ] **Step 6: 提交端口复用**

```bash
git add EasySign/Core/Transfer/TransferServer.swift EasySign/Core/Transfer/TransferListenerPortPolicy.swift Tests/TransferServerPortReuseTests.swift
git commit -m "fix(transfer): reuse listener port after network loss"
```

## Task 4: 把可信 endpoint 接入 TransferService 自动恢复

**Files:**

- Modify: `EasySign/Core/Transfer/TransferService.swift`
- Modify: `EasySign/Core/Transfer/TransferReconnectExecutionPolicy.swift`
- Modify: `Tests/TransferReconnectExecutionPolicyTests.swift`

- [ ] **Step 1: 写服务接线决策失败测试**

在纯策略测试中固定：旧 bound source 不能保存 hint；500ms 补发只有 source 仍为 active bound connection 且 listenPort 存在时才能发送；同 peer 的新 endpoint 替换旧值；clear/stop 删除 endpoint；自动 origin 始终 `pairingCode == nil` 且使用 token fingerprint。

- [ ] **Step 2: 运行策略测试并确认 RED**

Run the exact `swiftc` command in the test header.

Expected: failure for the new hint/send decision API.

- [ ] **Step 3: 在服务中维护并学习可信 endpoint**

增加主线程状态：

```swift
private var trustedReconnectEndpoints: [TransferAutoReconnect.PeerRef: TransferTrustedEndpoint] = [:]
```

在 `bindConnected` 安装 router 后：

- 处理 `.reconnectHint(port)`，跳主线程后校验 `source === activeConn`、bound fingerprint 和 peerRef；
- 用 `conn.remoteHost` + port 通过 hint policy 保存 endpoint；
- 更新当前 peer 的 coordinator endpoint key，但已连接状态不得启动拨号；
- 若 `listenPort` 已就绪立即发送本机 hint；500ms 后校验仍为同一 bound connection 再补发一次。

在 `server.onStateChange(.ready, port)` 主线程回调中更新 `listenPort` 后，对当前 bound connection 发送当前 hint，覆盖绑定时 listener 未 ready 或 listener 改端口。

- [ ] **Step 4: 接入 Bonjour 优先、直连回退的自动目标**

`currentAutomaticTarget()` 返回 `TransferAutomaticTarget?`。所有 coordinator 调用都使用目标的统一 `peerRef`/`reconnectEndpointKey`；`.dial` 执行处：

```swift
switch target {
case let .bonjour(peer):
    performOutbound(to: peer, pairingCode: nil, origin: .automatic(token))
case let .trusted(endpoint, _):
    performOutbound(host: endpoint.host, port: endpoint.port,
                    pairingCode: nil, origin: .automatic(token))
}
```

每次拨号前继续执行现有 token、busy、active connection、path、PeerRef 和 endpoint key 校验。Bonjour/可信 key 变化走现有 `.targetChanged`，旧 token 失效并对新目标开启新 generation；活动周期同 key 不重置，耗尽后有效恢复事件可重开。

- [ ] **Step 5: 清理与 UI 文案**

`clearPairedDevices()`、`stopServicesNow()` 删除可信 endpoint。显式 disconnect/peer bye 仍靠 coordinator target/suppression 阻止自动连接，不允许 endpoint 绕过。有限直连耗尽时显示“自动恢复暂未成功，等待网络变化或可手动重试”；没有 endpoint 时保留“等待设备重新出现或网络恢复”。

- [ ] **Step 6: 运行策略、协调器、自动目标、网络恢复回归测试**

Expected: every executable prints `ALL PASS`; specifically verify `[0,2,5,10]`, same-key duplicate, endpoint switch, user disconnect and stale token cases.

- [ ] **Step 7: Debug 构建确认服务接线可编译**

```bash
CLANG_MODULE_CACHE_PATH=/tmp/easysign-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/easysign-swiftpm-cache \
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug \
  -derivedDataPath /tmp/easysign-direct-reconnect-derived \
  -clonedSourcePackagesDirPath /tmp/easysign-source-packages \
  build CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: 提交服务集成**

```bash
git add EasySign/Core/Transfer/TransferService.swift EasySign/Core/Transfer/TransferReconnectExecutionPolicy.swift Tests/TransferReconnectExecutionPolicyTests.swift
git commit -m "fix(transfer): auto reconnect without Bonjour"
```

## Task 5: 真实网络回归、文档与发布

**Files:**

- Modify: `Tests/TransferLoopbackTests.swift`
- Modify: `CLAUDE.md`
- Modify: `docs/architecture.md`

- [ ] **Step 1: 扩展真实 loopback 测试**

在双方 TLS ready 后断言 `clientConn.remoteHost` 与 `serverConn.remoteHost` 可解析；bound handler 安装后互发 `reconnectHint` 并断言端口完整。

然后使用学到的 `host + server.port` 新建一条 `pairingCode: nil` 等价的 `.requirePinned(fingerprint: idB.fingerprint)` 客户端连接，强持有对应 server inbound connection，并断言双方进入 ready、指纹等于已配对记录。最后保留错误 fingerprint 必须失败的负向测试。这样真实覆盖“正确可信地址 + 正确 pin 成功”和“地址可能可达但错误 pin 拒绝”两侧。

- [ ] **Step 2: 运行真实 Network.framework 测试**

依次运行：

- `TransferLoopbackTests`
- `TransferDisconnectDetectionTests`
- `TransferServerPortReuseTests`
- `InboundRetainTests`

Expected: each ends with `ALL PASS`，没有挂起进程或无限 timer。

- [ ] **Step 3: 运行全部受影响纯测试**

依次运行：`WireMessageTests`、`TransferTrustedEndpointTests`、`TransferAutoReconnectTests`、`TransferReconnectCoordinatorTests`、`TransferReconnectExecutionPolicyTests`、`TransferNetworkRecoveryTests`、`PeerDiscoveryDedupTests`。

Expected: each ends with `ALL PASS`.

- [ ] **Step 4: 更新架构不变量**

把 `CLAUDE.md` 和 `docs/architecture.md` 中“saved manual host 只能显式 Retry、自动恢复必须有 Bonjour endpoint”的旧描述改为：自动恢复优先 Bonjour，已绑定连接学到的可信 IP/监听端口可作为无 Bonjour 回退；直连仍必须通过 deviceId 仲裁、path satisfied、有限事件周期和 TLS fingerprint pinning。

- [ ] **Step 5: 确认 tag 注入版本机制**

不修改工程内基线 `MARKETING_VERSION`。检查 `.github/workflows/release.yml` 仍从 `${GITHUB_REF_NAME#v}` 派生版本并在 xcodebuild 命令行注入；确认 `v1.3.2` 会生成 `MARKETING_VERSION=1.3.2`。

- [ ] **Step 6: 完整 Debug 与 Release 构建**

使用 Task 4 的 `/tmp` cache/DerivedData 参数分别运行 Debug、Release，预期均 `** BUILD SUCCEEDED **`。如果 SwiftPM 仍因沙箱权限失败，申请一次仅用于 xcodebuild 的受控提升权限后原样重跑，不把环境失败当作代码通过。

- [ ] **Step 7: 提交测试、文档与版本**

```bash
git add Tests/TransferLoopbackTests.swift CLAUDE.md docs/architecture.md
git commit -m "chore(release): prepare v1.3.2"
```

- [ ] **Step 8: 请求代码评审并修复所有阻塞问题**

使用 `superpowers:requesting-code-review`，给 reviewer 设计文档、计划、base `48d466b` 和 branch HEAD。修复后重新运行受影响测试与 Debug/Release 构建。

- [ ] **Step 9: 合并、最终验证、tag 和推送**

在主工作区确认只有用户原有未跟踪文件后，以非破坏方式合并 `codex/transfer-direct-reconnect`。重新执行 Task 5 Steps 2、3、6，再创建 annotated tag：

```bash
git tag -a v1.3.2 -m "EasySign v1.3.2"
git push origin main
git push origin v1.3.2
```

Expected: main 和 `v1.3.2` 均成功推送，且 tag 指向包含所有修复与版本更新的已验证提交。不得触碰 `docs/easysign-local-workbench-product-plan.md`。
