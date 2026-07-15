# 互传事件驱动自动重连实施计划

> **给执行代理：** 必须使用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans`，逐项执行本计划。所有步骤使用复选框跟踪。

**目标：** 让已配对设备在系统睡醒、网络恢复或 Bonjour 对端重新出现后，自动进行免配对码重连；有限尝试结束后停止计时，等待下一次恢复事件。

**架构：** 新增纯逻辑 `TransferReconnectCoordinator`，统一管理 generation、0/2/5/10 秒恢复周期、deviceId 单向拨号仲裁结果和主动断开抑制。`TransferService` 只负责把睡醒、网络路径、Bonjour 和连接回调转换为协调器事件并执行命令；`PeerDiscovery` 和 Core 层网络监听提供带 generation 的可靠事件源。

**技术栈：** Swift 6、Network.framework、AppKit 生命周期通知、GCD、独立 `swiftc @main` 测试、Xcode 16 同步文件组。

---

## 文件职责

- 新建 `EasySign/Core/Transfer/TransferReconnectCoordinator.swift`：纯状态机、尝试 token、有限延迟、主动断开抑制。
- 新建 `EasySign/Core/Transfer/TransferReconnectExecutionPolicy.swift`：服务接线使用的纯执行门禁、连接完成策略、生命周期动作顺序和 Bonjour 去抖。
- 新建 `EasySign/Core/Transfer/TransferNetworkMonitor.swift`：App 生命周期级 `NWPathMonitor` 和纯路径转换判断。
- 修改 `EasySign/Core/Transfer/TransferAutoReconnect.swift`：让 `PeerRef` 可作为抑制集合键；保留现有单向仲裁纯函数。
- 修改 `EasySign/Core/Transfer/TransferModels.swift`：为 `DiscoveredPeer` 提供稳定的恢复 endpoint 标识。
- 修改 `EasySign/Core/Transfer/PeerDiscovery.swift`：队列内管理 browser generation，拒绝旧回调并上报终态失败。
- 修改 `EasySign/Core/Transfer/TransferService.swift`：删除互相竞争的旧快速重试/自动重连路径，接入协调器、路径事件、超时 token 和入站抑制。
- 新建 `Tests/TransferReconnectCoordinatorTests.swift`：覆盖完整纯状态序列。
- 新建 `Tests/TransferReconnectExecutionPolicyTests.swift`：覆盖旧定时器/新手动连接、预期设备身份、路径丢失清理、睡醒动作顺序、自动免码和 stop/bye 策略。
- 新建 `Tests/TransferNetworkRecoveryTests.swift`：覆盖路径转换和 endpoint 变化判断。
- 修改 `Tests/PeerDiscoveryDedupTests.swift`：覆盖 browser generation gate。
- 修改 `Tests/TransferAutoReconnectTests.swift`：确认仲裁与 Hashable `PeerRef` 行为不回归。
- 修改 `CLAUDE.md`、`docs/architecture.md`：更新重连事件、不再描述旧三次快速重试路径。

---

### 任务 1：用失败测试固定重连状态机

**文件：**

- 新建：`Tests/TransferReconnectCoordinatorTests.swift`
- 新建：`EasySign/Core/Transfer/TransferReconnectCoordinator.swift`
- 修改：`EasySign/Core/Transfer/TransferAutoReconnect.swift:9-14`

- [ ] **步骤 1：先写协调器失败测试**

测试必须直接描述期望 API，不复制状态机实现：

```swift
import Foundation

@main
struct TransferReconnectCoordinatorTests {
    typealias Coordinator = TransferReconnectCoordinator
    static let peer = TransferAutoReconnect.PeerRef(deviceId: "peer-B", fingerprint: "fp-B")

    static func main() {
        var c = Coordinator()
        c.connected(to: peer, endpointKey: "ep-1")

        let first = c.unexpectedDrop(pathSatisfied: true, canDial: true, endpointKey: "ep-1")
        guard case let .dial(t0) = first else { return fail("断线后应立即拨号") }
        expect(t0.attempt == 0, "首次 attempt 应为 0")
        expect(t0.peer == peer && t0.endpointKey == "ep-1",
               "token 必须绑定预期设备与本轮 endpoint")

        let second = c.attemptFailed(t0)
        guard case let .schedule(t1, delay) = second else { return fail("首次失败应安排第二次") }
        expect(t1.attempt == 1 && delay == 2, "第二次应延迟 2 秒")
        expect(c.delayElapsed(t1) == .dial(t1), "2 秒到点后应拨号")

        guard case let .schedule(t2, d2) = c.attemptFailed(t1) else { return fail("第二次失败应继续") }
        expect(d2 == 5, "第三次应延迟 5 秒")
        expect(c.delayElapsed(t2) == .dial(t2), "第三次到点后应拨号")
        guard case let .schedule(t3, d3) = c.attemptFailed(t2) else { return fail("第三次失败应继续") }
        expect(d3 == 10, "第四次应延迟 10 秒")
        expect(c.delayElapsed(t3) == .dial(t3), "第四次到点后应拨号")
        expect(c.attemptFailed(t3) == .waitForEvent, "四次失败后必须停止定时重试")

        let fresh = c.recoveryEvent(pathSatisfied: true, canDial: true, busy: false, endpointKey: "ep-1")
        guard case let .dial(freshToken) = fresh else { return fail("新的恢复事件应重开周期") }
        expect(freshToken.generation != t0.generation, "新周期必须换 generation")

        let duplicate = c.recoveryEvent(pathSatisfied: true, canDial: true, busy: false, endpointKey: "ep-1")
        expect(duplicate == .none, "活动周期内重复事件不能重置次数")

        c.explicitlyConnecting(to: peer)
        expect(!c.accepts(freshToken), "用户手动连接必须立即使旧自动 token 失效")

        var manualRace = Coordinator()
        manualRace.connected(to: peer, endpointKey: "ep-1")
        guard case let .dial(r0) = manualRace.unexpectedDrop(
            pathSatisfied: true, canDial: true, endpointKey: "ep-1"
        ), case let .schedule(r1, _) = manualRace.attemptFailed(r0)
        else { return fail("需要一个等待中的自动任务") }
        manualRace.explicitlyConnecting(to: peer)
        expect(manualRace.delayElapsed(r1) == .none,
               "用户手动连接后旧延迟任务不得醒来拨号")

        c.networkUnavailable()
        expect(c.delayElapsed(freshToken) == .none, "网络中断后旧 token 必须失效")
        let restored = c.recoveryEvent(pathSatisfied: true, canDial: true, busy: false, endpointKey: "ep-1")
        guard case .dial = restored else { return fail("网络恢复应重新拨号") }

        c.userDisconnected(from: peer)
        expect(!c.allowsInbound(peer), "主动断开后应拒绝免码入站")
        expect(c.recoveryEvent(pathSatisfied: true, canDial: true, busy: false, endpointKey: "ep-1") == .none,
               "主动断开后恢复事件不得重连")
        c.explicitlyConnecting(to: peer)
        expect(c.allowsInbound(peer), "本机显式连接后解除抑制")

        c.connected(to: peer, endpointKey: "ep-1")
        let old = c.unexpectedDrop(pathSatisfied: true, canDial: true, endpointKey: "ep-1")
        guard case let .dial(oldToken) = old else { return fail("需要旧 token") }
        _ = c.recoveryEvent(pathSatisfied: true, canDial: true, busy: false, endpointKey: "ep-2")
        expect(!c.accepts(oldToken), "endpoint 变化后旧连接/超时回调必须失效")

        c.connected(to: peer, endpointKey: "ep-2")
        expect(c.unexpectedDrop(pathSatisfied: true, canDial: false, endpointKey: nil) == .waitForEvent,
               "deviceId 较大的一端只能等待拨入")

        print("ALL PASS")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fail(message) }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}
```

- [ ] **步骤 2：运行测试并确认 RED**

运行：

```bash
swiftc EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/TransferAutoReconnect.swift Tests/TransferReconnectCoordinatorTests.swift -o /tmp/transfer-reconnect-coordinator
```

预期：编译失败，明确提示找不到 `TransferReconnectCoordinator`，而不是测试语法错误。

- [ ] **步骤 3：实现最小纯状态机**

先把 `PeerRef` 改为 `Hashable`，然后创建：

```swift
import Foundation

struct TransferReconnectCoordinator {
    struct Token: Equatable {
        let generation: UInt
        let attempt: Int
        let peer: TransferAutoReconnect.PeerRef
        let endpointKey: String
    }

    enum Phase: Equatable {
        case inactive
        case dialing(Token)
        case waiting(Token)
        case waitingForEvent
    }

    enum Command: Equatable {
        case none
        case dial(Token)
        case schedule(Token, delay: TimeInterval)
        case waitForEvent
    }

    static let delays: [TimeInterval] = [0, 2, 5, 10]

    private(set) var generation: UInt = 0
    private(set) var phase: Phase = .inactive
    private(set) var target: TransferAutoReconnect.PeerRef?
    private(set) var endpointKey: String?
    private var suppressed = Set<TransferAutoReconnect.PeerRef>()

    mutating func connected(to peer: TransferAutoReconnect.PeerRef, endpointKey: String?) {
        generation &+= 1
        target = peer
        self.endpointKey = endpointKey
        phase = .inactive
    }

    mutating func unexpectedDrop(pathSatisfied: Bool, canDial: Bool, endpointKey: String?) -> Command {
        startCycle(pathSatisfied: pathSatisfied, canDial: canDial, busy: false, endpointKey: endpointKey)
    }

    mutating func recoveryEvent(pathSatisfied: Bool, canDial: Bool, busy: Bool,
                                endpointKey: String?) -> Command {
        guard target != nil, !busy else { return .none }
        if case .dialing = phase, endpointKey == self.endpointKey { return .none }
        if case .waiting = phase, endpointKey == self.endpointKey { return .none }
        return startCycle(pathSatisfied: pathSatisfied, canDial: canDial, busy: busy,
                          endpointKey: endpointKey)
    }

    mutating func peerBecameUnavailable() {
        generation &+= 1
        endpointKey = nil
        phase = target == nil ? .inactive : .waitingForEvent
    }

    mutating func attemptFailed(_ token: Token) -> Command {
        guard accepts(token), phase == .dialing(token) else { return .none }
        let nextAttempt = token.attempt + 1
        guard nextAttempt < Self.delays.count else {
            phase = .waitingForEvent
            return .waitForEvent
        }
        let next = Token(generation: generation, attempt: nextAttempt,
                         peer: token.peer, endpointKey: token.endpointKey)
        phase = .waiting(next)
        return .schedule(next, delay: Self.delays[nextAttempt])
    }

    mutating func delayElapsed(_ token: Token) -> Command {
        guard accepts(token), phase == .waiting(token) else { return .none }
        phase = .dialing(token)
        return .dial(token)
    }

    mutating func networkUnavailable() {
        generation &+= 1
        phase = target == nil ? .inactive : .waitingForEvent
    }

    mutating func userDisconnected(from peer: TransferAutoReconnect.PeerRef) {
        suppressed.insert(peer)
        stopTarget(peer)
    }

    mutating func peerSaidBye(_ peer: TransferAutoReconnect.PeerRef) { stopTarget(peer) }

    mutating func explicitlyConnecting(to peer: TransferAutoReconnect.PeerRef) {
        cancelAutomaticRecovery()
        suppressed.remove(peer)
    }

    mutating func cancelAutomaticRecovery() {
        generation &+= 1
        phase = .inactive
    }

    mutating func clearPeer(_ peer: TransferAutoReconnect.PeerRef) {
        suppressed.remove(peer)
        stopTarget(peer)
    }

    func allowsInbound(_ peer: TransferAutoReconnect.PeerRef) -> Bool {
        !suppressed.contains(peer)
    }

    func accepts(_ token: Token) -> Bool { token.generation == generation }

    mutating func stop() {
        generation &+= 1
        target = nil
        endpointKey = nil
        phase = .inactive
    }

    private mutating func startCycle(pathSatisfied: Bool, canDial: Bool, busy: Bool,
                                     endpointKey: String?) -> Command {
        guard let target, !suppressed.contains(target), !busy else { return .none }
        generation &+= 1
        self.endpointKey = endpointKey
        guard pathSatisfied, canDial, let endpointKey else {
            phase = .waitingForEvent
            return .waitForEvent
        }
        let token = Token(generation: generation, attempt: 0,
                          peer: target, endpointKey: endpointKey)
        phase = .dialing(token)
        return .dial(token)
    }

    private mutating func stopTarget(_ peer: TransferAutoReconnect.PeerRef) {
        guard target == peer else { return }
        stop()
    }
}
```

实现时如测试暴露 API 缺陷，只调整能让上述行为成立的最小部分，不提前接触 Network.framework。

- [ ] **步骤 4：运行测试并确认 GREEN**

运行：

```bash
swiftc EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/TransferAutoReconnect.swift EasySign/Core/Transfer/TransferReconnectCoordinator.swift Tests/TransferReconnectCoordinatorTests.swift -o /tmp/transfer-reconnect-coordinator && /tmp/transfer-reconnect-coordinator
```

预期：`ALL PASS`。

- [ ] **步骤 5：回归现有仲裁测试**

运行：

```bash
swiftc EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/TransferAutoReconnect.swift Tests/TransferAutoReconnectTests.swift -o /tmp/transfer-auto && /tmp/transfer-auto
```

预期：`ALL PASS`。

- [ ] **步骤 6：提交纯状态机**

```bash
git add EasySign/Core/Transfer/TransferAutoReconnect.swift EasySign/Core/Transfer/TransferReconnectCoordinator.swift Tests/TransferReconnectCoordinatorTests.swift
git commit -m "feat(transfer): add event-driven reconnect coordinator"
```

---

### 任务 2：让网络与 Bonjour 事件可判定、可去重

**文件：**

- 新建：`Tests/TransferNetworkRecoveryTests.swift`
- 新建：`EasySign/Core/Transfer/TransferNetworkMonitor.swift`
- 修改：`EasySign/Core/Transfer/TransferModels.swift:43-52`
- 修改：`EasySign/Core/Transfer/PeerDiscovery.swift:5-49`
- 修改：`Tests/PeerDiscoveryDedupTests.swift`

- [ ] **步骤 1：写网络转换和 endpoint 失败测试**

```swift
import Foundation
import Network

@main
struct TransferNetworkRecoveryTests {
    static func main() {
        expect(TransferNetworkTransition.next(previous: nil, current: true) == .initial,
               "首次可用建立基线，服务层同时把它作为一次有效恢复事件")
        expect(TransferNetworkTransition.next(previous: nil, current: false) == .becameUnavailable,
               "首次不可用要阻止拨号")
        expect(TransferNetworkTransition.next(previous: false, current: true) == .restored,
               "不可用→可用必须触发恢复")
        expect(TransferNetworkTransition.next(previous: true, current: true) == .unchanged,
               "重复可用不能重开周期")

        let a = DiscoveredPeer(deviceId: "A", name: "Mac", fingerprint: "fp",
                               endpoint: .hostPort(host: "127.0.0.1", port: 5000))
        let b = DiscoveredPeer(deviceId: "A", name: "Mac", fingerprint: "fp",
                               endpoint: .hostPort(host: "127.0.0.1", port: 5001))
        expect(a.reconnectEndpointKey != b.reconnectEndpointKey,
               "监听端口变化必须形成新的恢复事件")

        let service = NWEndpoint.service(name: "peer-A", type: "_easysign-transfer._tcp",
                                         domain: "local.", interface: nil)
        let s1 = DiscoveredPeer(deviceId: "A", name: "Mac", fingerprint: "fp",
                                endpoint: service, recoveryToken: "browser-7/change-1")
        let s2 = DiscoveredPeer(deviceId: "A", name: "Mac", fingerprint: "fp",
                                endpoint: service, recoveryToken: "browser-7/change-2")
        expect(s1.reconnectEndpointKey != s2.reconnectEndpointKey,
               "同一 Bonjour service 身份发生 changed 时也必须形成新恢复事件")
        print("ALL PASS")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1)
        }
    }
}
```

- [ ] **步骤 2：运行并确认 RED**

运行：

```bash
swiftc EasySign/Core/Transfer/TransferModels.swift Tests/TransferNetworkRecoveryTests.swift -o /tmp/transfer-network-recovery
```

预期：找不到 `TransferNetworkTransition` 和 `reconnectEndpointKey`。

- [ ] **步骤 3：实现路径转换和 Core 监听器**

```swift
import Foundation
import Network

enum TransferNetworkTransition: Equatable {
    case initial
    case unchanged
    case becameUnavailable
    case restored

    static func next(previous: Bool?, current: Bool) -> Self {
        switch (previous, current) {
        case (nil, true): .initial
        case (nil, false): .becameUnavailable
        case (false, true): .restored
        case (true, false): .becameUnavailable
        default: .unchanged
        }
    }
}

final class TransferNetworkMonitor {
    private final class State {
        var monitor: NWPathMonitor?
        var previousSatisfied: Bool?
    }
    private let queue = DispatchQueue(label: "transfer.network-path")
    private let state = State()
    private let onPathChanged: (Bool, TransferNetworkTransition) -> Void

    init(onPathChanged: @escaping (Bool, TransferNetworkTransition) -> Void) {
        self.onPathChanged = onPathChanged
    }

    func start() {
        let state = state
        let onPathChanged = onPathChanged
        queue.async {
            guard state.monitor == nil else { return }
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                guard state.monitor === monitor else { return }
                let current = path.status == .satisfied
                let transition = TransferNetworkTransition.next(previous: state.previousSatisfied,
                                                                 current: current)
                state.previousSatisfied = current
                onPathChanged(current, transition)
            }
            state.monitor = monitor
            monitor.start(queue: self.queue)
        }
    }

    func stop() {
        let state = state
        queue.async {
            state.monitor?.cancel()
            state.monitor = nil
            state.previousSatisfied = nil
        }
    }

    deinit {
        let state = state
        queue.async {
            state.monitor?.cancel()
            state.monitor = nil
            state.previousSatisfied = nil
        }
    }
}
```

给 `DiscoveredPeer` 增加：

```swift
let recoveryToken: String?

init(deviceId: String, name: String, fingerprint: String,
     endpoint: NWEndpoint, recoveryToken: String? = nil) {
    self.deviceId = deviceId
    self.name = name
    self.fingerprint = fingerprint
    self.endpoint = endpoint
    self.recoveryToken = recoveryToken
}

var reconnectEndpointKey: String {
    recoveryToken ?? String(describing: endpoint)
}
```

- [ ] **步骤 4：给 `PeerDiscovery` 增加 generation gate 的失败测试**

在 `PeerDiscoveryDedupTests` 中增加：

```swift
expect(PeerDiscoveryGenerationGate.accepts(updateGeneration: 3,
                                           currentGeneration: 3,
                                           isBrowsing: true),
       "当前 browser 可以发布")
expect(!PeerDiscoveryGenerationGate.accepts(updateGeneration: 2,
                                            currentGeneration: 3,
                                            isBrowsing: true),
       "旧 browser 回调必须丢弃")
expect(!PeerDiscoveryGenerationGate.accepts(updateGeneration: 3,
                                            currentGeneration: 3,
                                            isBrowsing: false),
       "stop 后的回调必须丢弃")
expect(PeerDiscoveryRecoveryToken.make(browserGeneration: 7, changeRevision: 1)
       != PeerDiscoveryRecoveryToken.make(browserGeneration: 7, changeRevision: 2),
       "Bonjour changed 必须推进恢复 token")
```

运行：

```bash
swiftc EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/PeerDiscovery.swift Tests/PeerDiscoveryDedupTests.swift -o /tmp/peer-discovery && /tmp/peer-discovery
```

预期：编译失败，找不到 `PeerDiscoveryGenerationGate`。

- [ ] **步骤 5：把 `PeerDiscovery` 可变状态收敛到自己的队列**

实现纯 gate，并让 `start()`/`stop()` 只向 `queue` 投递：

```swift
enum PeerDiscoveryGenerationGate {
    static func accepts(updateGeneration: UInt, currentGeneration: UInt,
                        isBrowsing: Bool) -> Bool {
        isBrowsing && updateGeneration == currentGeneration
    }
}
```

`start()` 内递增 generation、取消旧 browser、构造新 browser。`browseResultsChangedHandler` 和 `stateUpdateHandler` 都捕获本次 generation，并先调用 gate。浏览结果处理必须使用第二个参数 `Set<NWBrowser.Result.Change>`：只对匹配设备的 `.added`/`.changed` 推进 change revision，并把 `PeerDiscoveryRecoveryToken.make(browserGeneration:changeRevision:)` 写入 `DiscoveredPeer.recoveryToken`；不能只依赖 `String(describing: .service)`，因为 service 身份不含重新解析后的监听端口。未发生 change 的重复结果沿用原 token。

`.failed` 必须在同一 `transfer.discovery` 队列内依次递增 generation、取消当前 browser、置 `browser = nil`、清空 revision/peer 快照，然后再调用 `onPeersChanged([])` 和新增的 `onFailure`，且不启动无限重试；这样迟到的 results/state 回调会被 gate 拒绝。`stop()` 同样先递增 generation，再取消并清空。所有 `browser`/`generation`/revision/peer 快照读写都发生在该队列；回调闭包在 `start()` 前设置、启动后视为不可变。

- [ ] **步骤 6：运行网络和发现测试**

```bash
swiftc EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/TransferNetworkMonitor.swift Tests/TransferNetworkRecoveryTests.swift -o /tmp/transfer-network-recovery && /tmp/transfer-network-recovery
swiftc EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/PeerDiscovery.swift Tests/PeerDiscoveryDedupTests.swift -o /tmp/peer-discovery && /tmp/peer-discovery
```

预期：两项均输出 `ALL PASS`。

- [ ] **步骤 7：提交事件源改造**

```bash
git add EasySign/Core/Transfer/TransferNetworkMonitor.swift EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/PeerDiscovery.swift Tests/TransferNetworkRecoveryTests.swift Tests/PeerDiscoveryDedupTests.swift
git commit -m "feat(transfer): add recoverable network and discovery events"
```

---

### 任务 3：把 `TransferService` 统一到一个自动恢复入口

**文件：**

- 修改：`EasySign/Core/Transfer/TransferService.swift:20-56, 125-434, 782-880`
- 新建：`EasySign/Core/Transfer/TransferReconnectExecutionPolicy.swift`
- 新建：`Tests/TransferReconnectExecutionPolicyTests.swift`
- 测试：`Tests/TransferReconnectCoordinatorTests.swift`

- [ ] **步骤 1：先写服务接线策略的失败测试**

先在协调器测试中增加 busy/缺 endpoint 场景；再创建 `TransferReconnectExecutionPolicyTests.swift`，测试 API 必须由 `TransferService` 直接复用，不能在测试里复制判断：

```swift
var wake = Coordinator()
wake.connected(to: peer, endpointKey: "ep")
expect(wake.recoveryEvent(pathSatisfied: true, canDial: true, busy: true,
                          endpointKey: "ep") == .none,
       "睡醒时旧连接仍忙不能创建竞争连接")
let afterDrop = wake.unexpectedDrop(pathSatisfied: true, canDial: true, endpointKey: "ep")
guard case .dial = afterDrop else { return fail("稍后终态回调到达后必须开始恢复") }

var missing = Coordinator()
missing.connected(to: peer, endpointKey: "ep")
missing.peerBecameUnavailable()
expect(missing.recoveryEvent(pathSatisfied: true, canDial: false, busy: false,
                             endpointKey: nil) == .waitForEvent,
       "没有当前 endpoint 时不能拨旧地址")

var policyCoordinator = Coordinator()
policyCoordinator.connected(to: peer, endpointKey: "ep")
guard case let .dial(token) = policyCoordinator.unexpectedDrop(
    pathSatisfied: true, canDial: true, endpointKey: "ep"
) else { return fail("需要自动 token") }

let automatic = TransferConnectionOrigin.automatic(token)
expect(automatic.pairingCode(requested: "654321") == nil,
       "自动连接永远不能携带配对码")
expect(automatic.expectedFingerprint == peer.fingerprint,
       "自动连接必须把预期指纹传给 TLS pin")
expect(!TransferReconnectExecutionPolicy.mayStartAutomatic(
    token: token, tokenAccepted: true, busy: true, hasActiveConnection: true,
    pathSatisfied: true, currentPeer: peer, currentEndpointKey: "ep"),
    "用户连接或活动连接存在时旧自动任务不得拨号")
expect(!TransferReconnectExecutionPolicy.mayStartAutomatic(
    token: token, tokenAccepted: true, busy: false, hasActiveConnection: false,
    pathSatisfied: true,
    currentPeer: .init(deviceId: "peer-C", fingerprint: "fp-C"),
    currentEndpointKey: "ep"),
    "自动任务不能连接到非预期设备")
expect(!TransferReconnectExecutionPolicy.mayStartAutomatic(
    token: token, tokenAccepted: true, busy: false, hasActiveConnection: false,
    pathSatisfied: true, currentPeer: nil, currentEndpointKey: nil),
    "仅有手动 IP Retry/隐身模式时也不能把旧地址用于自动拨号")
expect(TransferReconnectExecutionPolicy.readyPeerMatches(token: token, actual: peer),
       "TLS 就绪后的配对记录必须与 token 预期设备完全一致")
expect(!TransferReconnectExecutionPolicy.readyPeerMatches(
    token: token,
    actual: .init(deviceId: "peer-C", fingerprint: peer.fingerprint)
), "只碰巧找到同一指纹但 deviceId 不同也不能绑定")

policyCoordinator.explicitlyConnecting(to: peer)
expect(!policyCoordinator.accepts(token), "显式连接必须使旧自动任务失效")
expect(TransferReconnectExecutionPolicy.completionDecision(
    attemptMatches: true, connectionMatches: true, tokenAccepted: false
) == .cleanupOnly, "旧 token 仍须按当前连接实例完成本地清理")
expect(TransferReconnectExecutionPolicy.completionDecision(
    attemptMatches: false, connectionMatches: true, tokenAccepted: true
) == .ignore, "旧 attempt 回调不得清理新连接")

expect(TransferReconnectExecutionPolicy.actions(for: .pathUnavailable)
       == [.cancelRecovery, .invalidateForNetworkLoss, .cleanupCurrentConnection, .waitForEvent],
       "网络不可用必须取消 timer、清理自动尝试并等待事件")
expect(TransferReconnectExecutionPolicy.actions(for: .pathRestored(reassertBonjour: true))
       == [.repairListener, .reassertBonjour, .restartDiscovery, .requestRecovery],
       "网络恢复必须先修基础设施再请求恢复")
expect(TransferReconnectExecutionPolicy.actions(for: .initialSatisfied(reassertBonjour: true))
       == [.repairListener, .reassertBonjour, .restartDiscovery, .requestRecovery],
       "首次确认网络可用也不能遗漏此前被 nil 路径挡住的恢复")
expect(TransferReconnectExecutionPolicy.actions(for: .wake(reassertBonjour: false)).first
       == .repairListener, "睡醒无论 busy 与否都先修 listener")
expect(TransferReconnectExecutionPolicy.shouldReassertBonjour(
    last: nil, now: 100, minimumInterval: 3), "首次修复必须重声明 Bonjour")
expect(!TransferReconnectExecutionPolicy.shouldReassertBonjour(
    last: 100, now: 101, minimumInterval: 3), "频繁回前台不能抖动 Bonjour")
expect(TransferReconnectExecutionPolicy.shouldReassertBonjour(
    last: 100, now: 103, minimumInterval: 3), "去抖窗口结束后允许重声明 Bonjour")
expect(TransferReconnectExecutionPolicy.lifecycleActions(for: .stop,
                                                          hasBoundConnection: true)
       == [.invalidateRecovery, .sendByeThenClose, .stopServices],
       "stop 必须先冲刷 bye 再停服务")
expect(TransferReconnectExecutionPolicy.lifecycleActions(for: .disconnect,
                                                          hasBoundConnection: true)
       == [.invalidateRecovery, .suppressCurrentPeer, .sendByeThenClose],
       "disconnect 必须保存本机抑制并冲刷 bye，但不能停 listener/discovery")

let hostRequest = TransferManualRetryRequest(
    target: .host(host: "192.168.1.8", port: 5555), pairingCode: "654321"
)
let hostRetry = TransferManualRetryPolicy.afterSuccessfulBind(hostRequest)
expect(hostRetry.target == hostRequest.target && hostRetry.pairingCode == nil,
       "手动 IP 成功绑定后必须保留 host/port 并改成免码 Retry")

let peerRequest = TransferManualRetryRequest(target: .peer(peer), pairingCode: "654321")
let peerRetry = TransferManualRetryPolicy.afterSuccessfulBind(peerRequest)
let newest = DiscoveredPeer(
    deviceId: peer.deviceId, name: "Peer", fingerprint: peer.fingerprint,
    endpoint: .hostPort(host: "127.0.0.1", port: 6002), recoveryToken: "browser-9/change-3"
)
expect(peerRetry.pairingCode == nil, "Bonjour 成功绑定后 Retry 必须免码")
expect(TransferManualRetryPolicy.resolvePeer(for: peerRetry, discovered: [newest])?
       .reconnectEndpointKey == "browser-9/change-3",
       "Bonjour Retry 每次必须按 PeerRef 解析当前最新 discovery token")
```

运行：

```bash
swiftc EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/TransferAutoReconnect.swift EasySign/Core/Transfer/TransferReconnectCoordinator.swift Tests/TransferReconnectCoordinatorTests.swift -o /tmp/transfer-reconnect-coordinator
/tmp/transfer-reconnect-coordinator
swiftc EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/TransferAutoReconnect.swift EasySign/Core/Transfer/TransferReconnectCoordinator.swift Tests/TransferReconnectExecutionPolicyTests.swift -o /tmp/transfer-reconnect-policy
```

预期：协调器原测试仍为 `ALL PASS`；策略测试因缺少 `TransferReconnectExecutionPolicy`/`TransferConnectionOrigin` 编译失败，形成明确 RED。

- [ ] **步骤 2：实现并跑通服务接线纯策略**

在新文件中实现测试所需的最小内部类型：

- `TransferConnectionOrigin.user` / `.automatic(Token)`；`pairingCode(requested:)` 对 automatic 恒返回 `nil`，`expectedFingerprint` 对 automatic 返回 token.peer.fingerprint、对 user 返回 nil。
- `TransferReconnectExecutionPolicy.mayStartAutomatic` 同时验证 token 当前有效、非 busy、`activeConn == nil`、路径已明确 `.satisfied`、当前 Bonjour `PeerRef`/recovery endpoint key 与 token 完全相同。
- `readyPeerMatches` 比较实际 TLS 指纹找到的 `PairedPeer` 的 deviceId 和 fingerprint，二者都必须与 token.peer 相同。
- `completionDecision`：旧 attempt/旧连接回调 `.ignore`；当前 attempt+当前连接但 token 已失效为 `.cleanupOnly`；三者都有效才 `.cleanupAndRetry`。
- 生命周期动作枚举固定 unavailable/restored/initial-satisfied/wake/stop 的顺序；`shouldReassertBonjour` 提供可测试的 3 秒去抖纯函数。
- 为 `ConnectionState` 增加只读 `isBusy`（connected/connecting/pairing 为 true），`TransferService` 不再散落复制 switch。
- `TransferManualRetryTarget` 和 `TransferManualRetryRequest` 均为 `Equatable`；request 用 `.host(host:port:)` 或 `.peer(PeerRef)` 保存用户目标及 pairingCode；`afterSuccessfulBind` 保留目标但把 code 置 nil；`resolvePeer` 每次从传入的最新 `discoveredPeers` 按 deviceId+fingerprint 解析，不缓存旧 `DiscoveredPeer`/endpoint。

`TransferReconnectExecutionPolicyTests.swift` 导入 `Foundation` 和 `Network`，使用与任务 1 相同的 `@main`、`expect`、`fail` 外壳，把步骤 1 的断言全部放入 `main()`，末尾输出 `ALL PASS`。

运行：

```bash
swiftc EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/TransferAutoReconnect.swift EasySign/Core/Transfer/TransferReconnectCoordinator.swift EasySign/Core/Transfer/TransferReconnectExecutionPolicy.swift Tests/TransferReconnectExecutionPolicyTests.swift -o /tmp/transfer-reconnect-policy
/tmp/transfer-reconnect-policy
```

预期：`ALL PASS`。

- [ ] **步骤 3：替换旧字段，建立单一连接来源**

在 `TransferService` 中新增：

```swift
private struct ActiveOutboundAttempt {
    let id: UUID
    let origin: TransferConnectionOrigin
}

private lazy var networkMonitor = TransferNetworkMonitor { [weak self] satisfied, transition in
    DispatchQueue.main.async { self?.handleNetworkPath(satisfied: satisfied, transition: transition) }
}
private var networkPathSatisfied: Bool?
private var reconnectCoordinator = TransferReconnectCoordinator()
private var reconnectWork: DispatchWorkItem?
private var reconnectScheduledToken: TransferReconnectCoordinator.Token?
private var activeOutboundAttempt: ActiveOutboundAttempt?
private var manualRetryRequest: TransferManualRetryRequest?
private var lastBonjourRepairAt: TimeInterval?
```

删除 `activeIsOutbound`、`lastReconnect`、`reconnectAttempts`、`reconnectGeneration`、`wasConnected`、`lastAutoReconnectAt`、`autoReconnecting`，并完整删除旧 `scheduleReconnect()`、`maybeAutoReconnect()` 及全部调用点，确保项目只剩 coordinator 一条自动恢复路径。保留 `lastManualConnect` 作为可选用户兜底，但自动协调器绝不能调用它。

每个用户 `connect`/`retry` 入口都先取消 `reconnectWork` 并清空 `reconnectScheduledToken`，调用 `cancelAutomaticRecovery()`（已知 Bonjour peer 时调用同时解除该 peer 抑制的 `explicitlyConnecting(to:)`），并按 attempt id 幂等清理尚未绑定的自动连接，再创建用户连接。手动 host/port 在 TLS `.ready` 前还不知道 peer，必须只失效旧 generation，识别实际 paired peer 后再解除对应抑制。

用户发起连接时构造 `TransferManualRetryRequest` 并调用 `installManualRetry(request)`：保存 request，同时令 `lastManualConnect` 通过统一 `executeManualRetryRequest` 执行它。成功 `bindConnected` 后用 `TransferManualRetryPolicy.afterSuccessfulBind` 生成同目标、`pairingCode: nil` 的 request 并重新安装，避免配对码轮换后 Retry 重放旧码；自动连接不得读写该 request/闭包。新用户连接覆盖 request，`stop()` 清空二者。

`executeManualRetryRequest` 对 `.host` 始终复用用户输入的 host/port；对 `.peer(PeerRef)` 每次调用 `TransferManualRetryPolicy.resolvePeer(for:discovered:)` 从**当前** `discoveredPeers` 取最新 recovery token，找不到就显示“等待设备重新出现”，绝不能捕获首次点击时的旧 `DiscoveredPeer`。两条路径 origin 都是 `.user`，因此手动 IP 仍是明确 fallback，但不会进入自动协调器。

- [ ] **步骤 4：接入服务生命周期事件**

`startServices()`：

- `networkMonitor.onPathChanged` 切回主线程调用 `handleNetworkPath`；
- `discovery.onPeersChanged` 更新列表前后比较最后设备的 endpoint key；消失时调用 `peerBecameUnavailable()`，出现或变化时调用统一恢复入口；
- 匹配设备消失或 `discovery.onFailure` 时，切回主线程后取消 `reconnectWork`、使 coordinator generation 失效，并按 attempt id 清理尚未绑定的自动尝试；只记录日志、清空过期列表并等待下一次睡醒/网络恢复；
- 最后启动 `networkMonitor`。

`handleNetworkPath` 必须完整映射四条分支，然后把纯策略返回的有序动作交给唯一 executor；未知的 `nil` 不能当作可用：

```swift
private func handleNetworkPath(satisfied: Bool, transition: TransferNetworkTransition) {
    networkPathSatisfied = satisfied
    let event: TransferReconnectExecutionPolicy.RecoveryEvent
    switch transition {
    case .becameUnavailable:
        event = .pathUnavailable
    case .restored:
        event = .pathRestored(reassertBonjour: shouldReassertBonjourNow())
    case .initial:
        guard satisfied else { return }
        event = .initialSatisfied(reassertBonjour: shouldReassertBonjourNow())
    case .unchanged:
        return
    }
    executeRecoveryActions(TransferReconnectExecutionPolicy.actions(for: event),
                           reason: "网络路径变化")
}
```

`executeRecoveryActions` 是服务执行恢复动作的唯一入口，严格按数组顺序解释：`.cancelRecovery` 取消 work/token；`.invalidateForNetworkLoss` 调用 `networkUnavailable()`；`.cleanupCurrentConnection` 按 attempt id/connection identity 幂等清理后 cancel；`.waitForEvent` 更新稳定失败文案；`.repairListener` 调用 `restartIfUnhealthy()`；`.reassertBonjour` 更新 `lastBonjourRepairAt` 并按 stealth 设置广播；`.restartDiscovery` 重启 browser；`.requestRecovery` 最后才调用统一恢复入口。已绑定连接在网络不可用时也要先幂等清理再 cancel，不能等待一个可能永不到达的 NWConnection 终态。token 失效只禁止消费新的重试次数，不能阻止连接实例清理。

`stop()` 与 `disconnect()` 不再手写顺序，而是分别调用 `executeLifecycleActions(TransferReconnectExecutionPolicy.lifecycleActions(...))`。executor 中 `.invalidateRecovery` 取消 work/token 并推进 coordinator；`.suppressCurrentPeer` 在清理 `lastConnectedPeer` 前调用 `userDisconnected(from:)`；`.sendByeThenClose` 复用 `closeBoundConnectionSendingBye`，先从服务状态移除当前连接，再 `send(.bye)`，在 send 完成或 0.5 秒兜底时 cancel；`.stopServices` 只有在触发冲刷后才停止发现/监听并清空手动重试状态。这样生命周期策略测试覆盖的就是服务实际执行路径，而不是装饰性旁路 API。

- [ ] **步骤 5：实现基础设施修复与统一事件入口**

```swift
private func shouldReassertBonjourNow(
    now: TimeInterval = Date().timeIntervalSinceReferenceDate
) -> Bool {
    TransferReconnectExecutionPolicy.shouldReassertBonjour(
        last: lastBonjourRepairAt, now: now, minimumInterval: 3
    )
}

private func requestAutomaticRecovery(reason: String, unexpectedDrop: Bool = false) {
    let busy: Bool = {
        switch connectionState {
        case .connected, .connecting, .pairing: true
        case .idle, .failed: false
        }
    }()
    let target = currentAutomaticTarget(busy: false)
    let endpointKey = target?.reconnectEndpointKey
    let command = unexpectedDrop
        ? reconnectCoordinator.unexpectedDrop(
            pathSatisfied: networkPathSatisfied == true,
            canDial: target != nil,
            endpointKey: endpointKey)
        : reconnectCoordinator.recoveryEvent(
            pathSatisfied: networkPathSatisfied == true,
            canDial: target != nil,
            busy: busy,
            endpointKey: endpointKey)
    executeReconnect(command, reason: reason)
}
```

`currentAutomaticTarget` 必须复用 `TransferAutoReconnect.target`，因此只有 deviceId 较小的一端能得到目标；每次拨号前重新从 `discoveredPeers` 解析，不能捕获旧 peer。隐身模式只关闭本机广播，不能启用手动 IP 自动 fallback 或绕过此仲裁。

- [ ] **步骤 6：执行协调器命令**

```swift
private func executeReconnect(_ command: TransferReconnectCoordinator.Command, reason: String) {
    switch command {
    case .none:
        return
    case .waitForEvent:
        reconnectWork?.cancel()
        reconnectWork = nil
        reconnectScheduledToken = nil
        connectionState = .failed("连接中断，等待网络或设备恢复后自动重连")
    case let .schedule(token, delay):
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.reconnectScheduledToken == token else { return }
            self.reconnectWork = nil
            self.reconnectScheduledToken = nil
            self.executeReconnect(self.reconnectCoordinator.delayElapsed(token), reason: "有限重试")
        }
        reconnectWork = work
        reconnectScheduledToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    case let .dial(token):
        reconnectWork?.cancel()
        reconnectWork = nil
        reconnectScheduledToken = nil
        let busy = connectionState.isBusy
        let peer = currentAutomaticTarget(busy: false)
        let currentRef = peer.map {
            TransferAutoReconnect.PeerRef(deviceId: $0.deviceId, fingerprint: $0.fingerprint)
        }
        guard TransferReconnectExecutionPolicy.mayStartAutomatic(
            token: token,
            tokenAccepted: reconnectCoordinator.accepts(token),
            busy: busy,
            hasActiveConnection: activeConn != nil,
            pathSatisfied: networkPathSatisfied == true,
            currentPeer: currentRef,
            currentEndpointKey: peer?.reconnectEndpointKey
        ) else {
            // token 失效或用户连接占用时静默退出，绝不能改 UI/取消用户连接。
            guard reconnectCoordinator.accepts(token), !busy, activeConn == nil else { return }
            reconnectCoordinator.peerBecameUnavailable()
            connectionState = .failed("连接中断，等待网络或设备恢复后自动重连")
            return
        }
        guard let peer else { return } // mayStartAutomatic 为 true 时必然存在；保留显式防御
        performOutbound(to: peer, pairingCode: nil, origin: .automatic(token))
    }
}
```

GCD 回调执行前必须通过 coordinator token 校验；所有用户连接入口在开始前取消 work 并推进 generation。`.dial` 还必须重新检查真实 busy 和 `activeConn == nil`，不能让旧自动任务改状态、取消或替换用户连接。

- [ ] **步骤 7：统一“连接尝试失败”和“已绑定连接断开”的收尾入口**

每次出站尝试在调用 `client.connect` **之前**创建 UUID attempt id，因此 `client == nil` 或同步抛错也能收口。抽出不依赖 conn 必然存在的幂等完成入口；`.failed`、`.cancelled`、同步创建失败、12 秒超时、`.ready` 后无指纹、找不到配对记录、自动尝试实际设备不匹配都进入它。连接已经 `bindConnected` 后，新的终态 handler 不再携带旧 attempt token，而是开启一个全新的恢复周期：

```swift
private func cleanupCurrentConnection(_ conn: TransferConnection) -> Bool {
    guard conn === activeConn else { return false }
    connectTimeoutWork?.cancel(); connectTimeoutWork = nil
    activeConn = nil
    activePeerFingerprint = nil
    fileManager.reset()
    return true
}

private func finishOutboundAttempt(id: UUID,
                                   conn: TransferConnection?,
                                   origin: TransferConnectionOrigin,
                                   failure: String?,
                                   consumeAutomaticFailure: Bool = true) {
    guard activeOutboundAttempt?.id == id else { return }
    if let conn, conn !== activeConn { return }

    let tokenAccepted: Bool = {
        if case let .automatic(token) = origin { return reconnectCoordinator.accepts(token) }
        return true
    }()
    let decision = TransferReconnectExecutionPolicy.completionDecision(
        attemptMatches: true,
        connectionMatches: conn == nil || conn === activeConn,
        tokenAccepted: tokenAccepted && consumeAutomaticFailure
    )
    guard decision != .ignore else { return }

    activeOutboundAttempt = nil
    connectTimeoutWork?.cancel(); connectTimeoutWork = nil
    if let activeConn { _ = cleanupCurrentConnection(activeConn) }

    switch (origin, decision) {
    case let (.automatic(token), .cleanupAndRetry):
        executeReconnect(reconnectCoordinator.attemptFailed(token), reason: failure ?? "连接断开")
    case (.automatic, .cleanupOnly):
        connectionState = .failed("连接中断，等待网络或设备恢复后自动重连")
    case (.user, _):
        connectionState = failure.map(ConnectionState.failed) ?? .idle
    case (_, .ignore):
        break
    }
}

private func handleBoundConnectionDrop(_ conn: TransferConnection, failure: String?) {
    guard cleanupCurrentConnection(conn) else { return }
    guard !userStopped, reconnectCoordinator.target != nil else {
        connectionState = failure.map(ConnectionState.failed) ?? .idle
        return
    }
    requestAutomaticRecovery(reason: failure ?? "连接断开", unexpectedDrop: true)
}
```

入站和出站连接绑定后都安装 `handleBoundConnectionDrop`；原连接方向不再决定是否重连。自动尝试一旦绑定成功，`bindConnected` 必须清空 `activeOutboundAttempt`、调用 `reconnectCoordinator.connected` 并丢弃旧 token，下一次断线是新恢复周期，不能继续消费旧 attempt。`cleanupCurrentConnection` 只按 connection identity 决定能否清理，绝不能因 token 已失效而拒绝清理。

- [ ] **步骤 8：给超时和出站回调携带 `ConnectionOrigin`**

调整以下方法签名：

```swift
private func performOutbound(host: String, port: UInt16, pairingCode: String?, origin: TransferConnectionOrigin)
private func performOutbound(to peer: DiscoveredPeer, pairingCode: String?, origin: TransferConnectionOrigin)
private func beginOutbound(_ conn: TransferConnection, attemptID: UUID, pairingCode: String?, origin: TransferConnectionOrigin)
private func armConnectTimeout(_ conn: TransferConnection, attemptID: UUID, origin: TransferConnectionOrigin)
private func outboundReady(conn: TransferConnection, attemptID: UUID, pairingCode: String?, origin: TransferConnectionOrigin)
```

方法入口先用 `origin.pairingCode(requested:)` 归一化配对码，保证 automatic 恒为 nil；`.automatic(token)` 创建 NWConnection 时直接使用 `.requirePinned(fingerprint: token.peer.fingerprint)`，应用层就绪后仍执行 deviceId+fingerprint 双重核对。超时闭包先按 attempt id 和 `conn === activeConn` 找当前尝试，然后无论 token 是否仍有效都调用 `finishOutboundAttempt`；token 只决定 `.cleanupOnly` 还是 `.cleanupAndRetry`。自动连接的同步创建失败、`.failed`、`.cancelled`、超时、指纹/配对记录/预期身份校验失败都必须只完成一次。

`outboundReady` 对 `.automatic(token)` 先按实际 TLS fingerprint 查 paired peer，再用 `readyPeerMatches` 同时验证 deviceId+fingerprint；不匹配就取消并进入本次失败，不能绑定“另一台也已配对的设备”。`bindConnected` 成功时取消 `reconnectWork`，清空 attempt，调用 `reconnectCoordinator.connected`，并用不捕获 attempt token 的已绑定 handler 覆盖出站预绑定 handler。用户 origin 成功后把 `manualRetryRequest` 交给 `afterSuccessfulBind`，再调用 `installManualRetry` 替换为免码 Retry。

- [ ] **步骤 9：修正睡醒处理顺序**

`onWokeOrActivated` 只构造 `.wake(reassertBonjour: shouldReassertBonjourNow())`，然后调用同一个 `executeRecoveryActions`。策略动作的第一项始终是 `.repairListener`，最后才是 `.requestRecovery`。删除旧的 `reconnectAttempts`、`lastAutoReconnectAt` 门禁；用新的 `lastBonjourRepairAt` + 纯 gate 保留独立 3 秒 Bonjour 去抖，确保残留 `.connected/.connecting` 不会阻止 listener 修复，也不会因频繁 `didBecomeActive` 反复重建 browser/广播。

- [ ] **步骤 10：验证服务策略和实际接线**

```bash
swiftc EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/TransferAutoReconnect.swift EasySign/Core/Transfer/TransferReconnectCoordinator.swift EasySign/Core/Transfer/TransferReconnectExecutionPolicy.swift Tests/TransferReconnectExecutionPolicyTests.swift -o /tmp/transfer-reconnect-policy
/tmp/transfer-reconnect-policy
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -derivedDataPath /tmp/EasySignDerivedData-transfer-auto-reconnect build
```

预期：策略测试 `ALL PASS`，且构建输出 `** BUILD SUCCEEDED **`。如果编译失败，只修复新 API 接线，不改变已通过的纯状态行为。

- [ ] **步骤 11：提交统一重连入口**

```bash
git add EasySign/Core/Transfer/TransferService.swift EasySign/Core/Transfer/TransferReconnectExecutionPolicy.swift Tests/TransferReconnectExecutionPolicyTests.swift
git commit -m "fix(transfer): unify automatic reconnect flow"
```

---

### 任务 4：封住主动断开后被重新拨入的缺口

**文件：**

- 修改：`EasySign/Core/Transfer/TransferService.swift:227-252, 500-530, 584-662, 777-780`
- 修改：`EasySign/Core/Transfer/TransferReconnectExecutionPolicy.swift`
- 测试：`Tests/TransferReconnectCoordinatorTests.swift`
- 测试：`Tests/TransferReconnectExecutionPolicyTests.swift`

- [ ] **步骤 1：补 `.bye` 丢失与显式恢复测试**

协调器测试增加以下顺序：连接成功 → `userDisconnected` → 模拟 `.bye` 丢失后的远端免码入站，`allowsInbound` 必须为 false → 睡醒/网络事件返回 `.none` → 本机显式 Connect 后才恢复允许。再覆盖 `peerSaidBye` 只停止自动恢复、不加入本机 suppression set。

策略测试增加尚不存在的入站路由 API：

```swift
expect(TransferReconnectExecutionPolicy.inboundDecision(
    isPairedCodeless: true, locallyAllowed: false
) == .rejectAndCancel, "本机主动断开后即使 bye 丢失也必须拒绝免码入站")
expect(TransferReconnectExecutionPolicy.inboundDecision(
    isPairedCodeless: false, locallyAllowed: false
) == .continuePairing, "未知设备首次配对不能被已配对 suppression 误伤")
```

- [ ] **步骤 2：确认新增测试 RED/GREEN**

先运行协调器测试，预期顺序测试通过；再编译策略测试，预期因缺少 `inboundDecision` 明确 RED。实现 `.rejectAndCancel` / `.acceptCodeless` / `.continuePairing` 三态纯决策后跑到 `ALL PASS`，再接入服务。

```bash
swiftc EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/TransferAutoReconnect.swift EasySign/Core/Transfer/TransferReconnectCoordinator.swift Tests/TransferReconnectCoordinatorTests.swift -o /tmp/transfer-reconnect-coordinator
/tmp/transfer-reconnect-coordinator
swiftc EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/TransferAutoReconnect.swift EasySign/Core/Transfer/TransferReconnectCoordinator.swift EasySign/Core/Transfer/TransferReconnectExecutionPolicy.swift Tests/TransferReconnectExecutionPolicyTests.swift -o /tmp/transfer-reconnect-policy
```

GREEN 时再运行 `/tmp/transfer-reconnect-policy`，预期 `ALL PASS`。

- [ ] **步骤 3：入站绑定前执行本地抑制检查**

在 `inboundReady` 识别是否为 paired codeless 后、`bindConnected` 前调用上述纯策略：

```swift
let ref = TransferAutoReconnect.PeerRef(deviceId: paired.deviceId,
                                        fingerprint: paired.fingerprint)
switch TransferReconnectExecutionPolicy.inboundDecision(
    isPairedCodeless: true,
    locallyAllowed: reconnectCoordinator.allowsInbound(ref)
) {
case .rejectAndCancel:
    logger.log(.info, tool: "transfer", "拒绝用户主动断开设备的自动回连：\(paired.name)")
    conn.cancel()
    return
case .acceptCodeless:
    bindConnected(conn: conn, peer: paired)
case .continuePairing:
    assertionFailure("已配对免码路径不应进入首次配对")
}
```

只有已配对免码入站走抑制；未知设备的首次配对仍按原配对码和限速流程处理。

- [ ] **步骤 4：显式连接解除对应抑制**

- `connect(to:pairingCode:)` 如果能按 fingerprint 找到 paired peer，先调用 `explicitlyConnecting(to:)`。
- 手动 host/port 无法预知 fingerprint；在 `.user` origin 的 `outboundReady` 识别到 paired peer 后、`bindConnected` 前解除对应抑制。
- 自动 origin 绝不能解除抑制。
- `clearPairedDevices` 对每个旧 peer 调用 `clearPeer` 后再清存储。
- `handlePeerBye` 调用 `peerSaidBye` 并取消当前重连 work。
- 所有显式入口同时取消 `reconnectWork` 并失效旧 generation；不能只解除 suppression。

- [ ] **步骤 5：验证主动断开行为和构建**

```bash
swiftc EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/TransferAutoReconnect.swift EasySign/Core/Transfer/TransferReconnectCoordinator.swift Tests/TransferReconnectCoordinatorTests.swift -o /tmp/transfer-reconnect-coordinator && /tmp/transfer-reconnect-coordinator
swiftc EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/TransferAutoReconnect.swift EasySign/Core/Transfer/TransferReconnectCoordinator.swift EasySign/Core/Transfer/TransferReconnectExecutionPolicy.swift Tests/TransferReconnectExecutionPolicyTests.swift -o /tmp/transfer-reconnect-policy && /tmp/transfer-reconnect-policy
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -derivedDataPath /tmp/EasySignDerivedData-transfer-auto-reconnect build
```

预期：协调器和服务策略均 `ALL PASS`，构建成功。

- [ ] **步骤 6：提交主动断开保护**

```bash
git add EasySign/Core/Transfer/TransferService.swift EasySign/Core/Transfer/TransferReconnectCoordinator.swift EasySign/Core/Transfer/TransferReconnectExecutionPolicy.swift Tests/TransferReconnectCoordinatorTests.swift Tests/TransferReconnectExecutionPolicyTests.swift
git commit -m "fix(transfer): preserve explicit disconnect across reconnects"
```

---

### 任务 5：运行传输回归并更新架构说明

**文件：**

- 修改：`CLAUDE.md`
- 修改：`docs/architecture.md`
- 修改：`Tests/TransferBonjourEndpointTests.swift`
- 验证：`Tests/TransferAutoReconnectTests.swift`
- 验证：`Tests/TransferReconnectCoordinatorTests.swift`
- 验证：`Tests/TransferReconnectExecutionPolicyTests.swift`
- 验证：`Tests/TransferNetworkRecoveryTests.swift`
- 验证：`Tests/PeerDiscoveryDedupTests.swift`
- 验证：`Tests/TransferDisconnectDetectionTests.swift`
- 验证：`Tests/TransferBonjourEndpointTests.swift`
- 验证：`Tests/TransferRepairDeadlockTests.swift`

- [ ] **步骤 1：更新中文架构说明**

将旧“2/4/8 秒三次快速重连 + maybeAutoReconnect 接管”的描述替换为：睡醒、网络恢复、匹配设备出现/Bonjour change token 变化驱动有限 0/2/5/10 秒恢复窗口；耗尽后无定时器；只有较小 deviceId 拨号；主动断开使用 `.bye` 加本机抑制。补充未知网络路径不拨号、自动 token 绑定预期 PeerRef+discovery token、用户连接使旧自动任务失效、Bonjour 3 秒去抖，以及手动 IP 只作为显式免码 Retry fallback 的不变量。

同时把 `TransferBonjourEndpointTests` 对已私有化 `advertiseInfo` 的直接赋值改成公开队列安全 API，避免现有回归测试因接口漂移无法编译：

```swift
server.setAdvertiseInfo((deviceId: serverDeviceId,
                         name: "ServerMac",
                         fingerprint: idB.fingerprint))
```

- [ ] **步骤 2：运行全部纯逻辑回归**

```bash
swiftc EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/TransferAutoReconnect.swift EasySign/Core/Transfer/TransferReconnectCoordinator.swift Tests/TransferReconnectCoordinatorTests.swift -o /tmp/transfer-reconnect-coordinator && /tmp/transfer-reconnect-coordinator
swiftc EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/TransferAutoReconnect.swift EasySign/Core/Transfer/TransferReconnectCoordinator.swift EasySign/Core/Transfer/TransferReconnectExecutionPolicy.swift Tests/TransferReconnectExecutionPolicyTests.swift -o /tmp/transfer-reconnect-policy && /tmp/transfer-reconnect-policy
swiftc EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/TransferAutoReconnect.swift Tests/TransferAutoReconnectTests.swift -o /tmp/transfer-auto && /tmp/transfer-auto
swiftc EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/TransferNetworkMonitor.swift Tests/TransferNetworkRecoveryTests.swift -o /tmp/transfer-network-recovery && /tmp/transfer-network-recovery
swiftc EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/PeerDiscovery.swift Tests/PeerDiscoveryDedupTests.swift -o /tmp/peer-discovery && /tmp/peer-discovery
```

预期：五项均为 `ALL PASS`。

- [ ] **步骤 3：运行真实 Network.framework 回归**

按各测试文件需要编译 Transfer 源码，排除 `TransferService.swift` 和包含另一个 `@main` 的测试文件，依次运行：

```bash
swiftc EasySign/Core/Transfer/CertFingerprint.swift EasySign/Core/Transfer/DeviceIdentity.swift EasySign/Core/Transfer/TransferTLS.swift EasySign/Core/Transfer/WireMessage.swift EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/PeerDiscovery.swift EasySign/Core/Transfer/TransferServer.swift EasySign/Core/Transfer/TransferClient.swift Tests/TransferDisconnectDetectionTests.swift -o /tmp/transfer-disconnect && /tmp/transfer-disconnect
```

再执行其余两个现有回归测试：

```bash
swiftc EasySign/Core/Transfer/CertFingerprint.swift EasySign/Core/Transfer/DeviceIdentity.swift EasySign/Core/Transfer/TransferTLS.swift EasySign/Core/Transfer/WireMessage.swift EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/PairingCrypto.swift EasySign/Core/Transfer/PairingManager.swift EasySign/Core/Transfer/PeerDiscovery.swift EasySign/Core/Transfer/TransferServer.swift EasySign/Core/Transfer/TransferClient.swift Tests/TransferBonjourEndpointTests.swift -o /tmp/transfer-bonjour-endpoint
/tmp/transfer-bonjour-endpoint

swiftc EasySign/Core/Transfer/CertFingerprint.swift EasySign/Core/Transfer/TransferTLS.swift EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/WireMessage.swift EasySign/Core/Transfer/PairingCrypto.swift EasySign/Core/Transfer/PairingManager.swift EasySign/Core/Transfer/BoundInboundRouter.swift Tests/TransferRepairDeadlockTests.swift -o /tmp/transfer-repair-deadlock
/tmp/transfer-repair-deadlock
```

预期均以 `ALL PASS` 结束；Bonjour 测试若受当前网络环境限制，必须记录实际失败信息，不能用构建成功替代。

- [ ] **步骤 4：运行最终 Debug 构建**

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -derivedDataPath /tmp/EasySignDerivedData-transfer-auto-reconnect build
```

预期：`** BUILD SUCCEEDED **`。

- [ ] **步骤 5：执行两台 Mac 手工验收**

1. 两台已配对并连接，休眠 deviceId 较小的一台，唤醒后确认自动免码连接。
2. 休眠 deviceId 较大的一台，确认它恢复监听/广播并由较小端拨入。
3. 关闭再开启任意一台 Wi-Fi，确认恢复事件触发有限窗口。
4. 对端保持离线超过恢复窗口，确认日志不再出现新尝试；对端重新出现后再次自动连接。
5. 用户点击“断开”，模拟/观察 `.bye` 未送达的情况，确认对端不能把本机自动拉回。
6. 在 2/5/10 秒自动等待期间手动点击 Connect/Retry，确认旧自动任务不会取消或覆盖用户连接。
7. 连续快速切换前后台，确认 listener 会修复，但 browser/广播不会每次都重建。
8. 首次配对成功且配对码轮换后断网，点击 Retry，确认走同一端点免码重连而不是重放旧配对码。
9. 执行完整 `stop()`，确认对端收到 `.bye`（或丢失时本机也不残留自动 timer），监听/发现随后停止。
10. 确认 UI 不会无限停在“连接中”，且自动恢复全过程不需要输入新配对码。

- [ ] **步骤 6：提交文档和最终回归说明**

```bash
git add CLAUDE.md docs/architecture.md Tests/TransferBonjourEndpointTests.swift
git commit -m "test(transfer): refresh reconnect regressions and docs"
```

---

## 完成条件

- 新增测试先失败、再因对应最小实现通过，保留 RED/GREEN 证据。
- 所有自动连接都传 `pairingCode: nil`，配对码仅用于首次配对。
- 自动 attempt token 同时绑定 generation、attempt、预期 PeerRef 和 Bonjour recovery token；TLS 实际身份不符时拒绝绑定。
- 旧 `reconnectAttempts`/`wasConnected`/`activeIsOutbound` 重连门禁完全删除。
- 睡醒处理先修基础设施，再判断连接忙碌状态。
- 用户 Connect/Retry 会取消 work、推进 generation，旧自动回调只能清理自己的连接，不能影响新用户连接。
- 网络 path 未知/不可用时不拨号；不可用时当前连接按实例幂等清理，token 失效不能导致 UI 卡在 connecting。
- Bonjour changed 能推进 recovery token，频繁前台通知受独立去抖保护。
- 有限窗口耗尽后不存在挂起定时器；新恢复事件可重开周期。
- 用户主动断开在 `.bye` 丢失时也保持断开。
- 成功配对后 Retry 改为免码路径；仅手动 IP/隐身模式不能绕过 deviceId 仲裁触发自动拨号。
- `disconnect()` 和 `stop()` 都先尝试冲刷 `.bye` 再关闭当前连接。
- Debug 构建成功，相关纯逻辑和 Network.framework 测试通过。
