import Foundation
import Network

/// 坐实:同一台设备经多个接口(Wi-Fi + P2P)被 Bonjour 发现时,会产生 deviceId 相同的多条结果,
/// 必须按 deviceId 去重,否则 SwiftUI ForEach(id: deviceId) 出现重复 id → 渲染异常/告警。
///
/// 期望输出:`ALL PASS`,否则 `FAIL: ...` 到 stderr + exit(1)。

@main
struct PeerDiscoveryDedupTests {
    typealias Candidate = PeerDiscoveryCandidate<String>
    typealias Reducer = PeerDiscoverySnapshotReducer<String>

    static func main() {
        let ep1 = NWEndpoint.hostPort(host: "127.0.0.1", port: 5000)
        let ep2 = NWEndpoint.hostPort(host: "127.0.0.2", port: 5000)
        let peers = [
            DiscoveredPeer(deviceId: "A", name: "MacA", fingerprint: "fa", endpoint: ep1),
            DiscoveredPeer(deviceId: "B", name: "MacB", fingerprint: "fb", endpoint: ep1),
            DiscoveredPeer(deviceId: "A", name: "MacA", fingerprint: "fa", endpoint: ep2),  // 同一设备另一接口
        ]
        let out = PeerDiscovery.deduped(peers)
        expect(out.count == 2, "同一 deviceId 应只保留一条,实际 \(out.count)")
        expect(out.map(\.deviceId) == ["A", "B"], "应保留首次出现顺序 [A, B],实际 \(out.map(\.deviceId))")
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

        testSnapshotReducer()
        testDiscoveryLifecycle()
        testCallbackStoreReentry()
        print("ALL PASS")
    }

    static func testSnapshotReducer() {
        let a1 = Candidate(value: "A/wifi", deviceId: "A")
        let a2 = Candidate(value: "A/p2p", deviceId: "A")
        let b1 = Candidate(value: "B/wifi", deviceId: "B")
        let b2 = Candidate(value: "B/p2p", deviceId: "B")

        var nonselectedRemoval = Reducer()
        let initial = nonselectedRemoval.reduce(
            snapshot: [a1, a2, b1],
            changes: [.added(a1), .added(a2), .added(b1)],
            browserGeneration: 7
        )
        let initialAToken = selection(for: "A", in: initial)?.recoveryToken
        let afterNonselectedRemoval = nonselectedRemoval.reduce(
            snapshot: [a1, b1],
            changes: [.removed(a2)],
            browserGeneration: 7
        )
        expect(selection(for: "A", in: afterNonselectedRemoval)?.candidate == a1,
               "移除 nonselected 接口必须保留当前 selected")
        expect(selection(for: "A", in: afterNonselectedRemoval)?.recoveryToken == initialAToken,
               "移除 nonselected 接口不得推进设备 token")

        let afterUnrelatedChange = nonselectedRemoval.reduce(
            snapshot: [a1, b2],
            changes: [.changed(old: b1, new: b2)],
            browserGeneration: 7
        )
        expect(selection(for: "A", in: afterUnrelatedChange)?.recoveryToken == initialAToken,
               "无关设备 changed 不得推进目标设备 token")

        var selectedRemoval = Reducer()
        let selectedInitial = selectedRemoval.reduce(
            snapshot: [a1, a2],
            changes: [.added(a1), .added(a2)],
            browserGeneration: 8
        )
        let selectedInitialToken = selection(for: "A", in: selectedInitial)?.recoveryToken
        let afterSelectedRemoval = selectedRemoval.reduce(
            snapshot: [a2],
            changes: [.removed(a1)],
            browserGeneration: 8
        )
        expect(selection(for: "A", in: afterSelectedRemoval)?.candidate == a2,
               "移除 selected 接口后必须切换到仍活跃候选")
        expect(selection(for: "A", in: afterSelectedRemoval)?.recoveryToken != selectedInitialToken,
               "selected 接口切换必须推进设备 token")
        let afterLastRemoval = selectedRemoval.reduce(
            snapshot: [],
            changes: [.removed(a2)],
            browserGeneration: 8
        )
        expect(afterLastRemoval.isEmpty && selectedRemoval.recoveryToken(for: "A") == nil,
               "最后接口移除后必须清空 snapshot/token")

        let serviceA = Candidate(value: "same-service", deviceId: "A")
        var identicalChanged = Reducer()
        let beforeChanged = identicalChanged.reduce(
            snapshot: [serviceA],
            changes: [.added(serviceA)],
            browserGeneration: 9
        )
        let beforeChangedToken = selection(for: "A", in: beforeChanged)?.recoveryToken
        let afterChanged = identicalChanged.reduce(
            snapshot: [serviceA],
            changes: [.changed(old: serviceA, new: serviceA)],
            browserGeneration: 9
        )
        expect(selection(for: "A", in: afterChanged)?.recoveryToken != beforeChangedToken,
               "即使 service 身份字符串相同，changed 也必须推进 token")

        let changedToB = Candidate(value: "A/wifi", deviceId: "B")
        var deviceIdChanged = Reducer()
        let deviceInitial = deviceIdChanged.reduce(
            snapshot: [a1, a2],
            changes: [.added(a1), .added(a2)],
            browserGeneration: 10
        )
        let oldAToken = selection(for: "A", in: deviceInitial)?.recoveryToken
        let deviceChanged = deviceIdChanged.reduce(
            snapshot: [a2, changedToB],
            changes: [.changed(old: a1, new: changedToB)],
            browserGeneration: 10
        )
        expect(selection(for: "A", in: deviceChanged)?.candidate == a2,
               "deviceId changed 必须从 old device 活跃候选移除旧 result")
        expect(selection(for: "A", in: deviceChanged)?.recoveryToken != oldAToken,
               "old device 的 selected 切换必须推进其 token")
        expect(selection(for: "B", in: deviceChanged)?.candidate == changedToB,
               "deviceId changed 必须把 new result 加入新设备")
        expect(selection(for: "B", in: deviceChanged)?.recoveryToken != nil,
               "deviceId changed 必须为 new device 生成 token")
    }

    static func testDiscoveryLifecycle() {
        var lifecycle = PeerDiscoveryLifecycleState()
        let first = lifecycle.beginBrowsing()
        expect(lifecycle.accepts(updateGeneration: first), "当前 browser generation 应被接受")
        lifecycle.invalidateBrowsing()
        expect(!lifecycle.accepts(updateGeneration: first),
               "failure/stop 必须先失效旧 generation")
        let restarted = lifecycle.beginBrowsing()
        expect(restarted != first && lifecycle.accepts(updateGeneration: restarted),
               "restart 必须创建可接受的新 generation")
        expect(!lifecycle.accepts(updateGeneration: first),
               "restart 后旧 browser callback 必须继续被拒绝")
    }

    static func testCallbackStoreReentry() {
        let callbacks = PeerDiscoveryCallbackStore()
        let invoked = LockedFlag()
        callbacks.onPeersChanged = { _ in
            invoked.setTrue()
            callbacks.onPeersChanged = nil
        }
        let snapshot = callbacks.onPeersChanged
        snapshot?([])
        expect(invoked.value && callbacks.onPeersChanged == nil,
               "callback 必须在锁外调用，允许回调中重配而不死锁")
    }

    static func selection(for deviceId: String,
                          in selections: [Reducer.Selection]) -> Reducer.Selection? {
        selections.first { $0.deviceId == deviceId }
    }

    static func expect(_ c: Bool, _ m: String) {
        if !c {
            FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8))
            exit(1)
        }
    }

    final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = false

        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func setTrue() {
            lock.lock()
            storage = true
            lock.unlock()
        }
    }
}
