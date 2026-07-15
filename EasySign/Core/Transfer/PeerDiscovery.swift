import Foundation
import Network

enum PeerDiscoveryGenerationGate {
    static func accepts(updateGeneration: UInt, currentGeneration: UInt,
                        isBrowsing: Bool) -> Bool {
        isBrowsing && updateGeneration == currentGeneration
    }
}

enum PeerDiscoveryRecoveryToken {
    static func make(browserGeneration: UInt, changeRevision: UInt) -> String {
        "browser-\(browserGeneration)/change-\(changeRevision)"
    }
}

struct PeerDiscoveryCandidate<Value: Hashable & Sendable>: Hashable, Sendable {
    let value: Value
    let deviceId: String
}

enum PeerDiscoveryCandidateChange<Value: Hashable & Sendable>: Sendable {
    case added(PeerDiscoveryCandidate<Value>)
    case removed(PeerDiscoveryCandidate<Value>)
    case changed(old: PeerDiscoveryCandidate<Value>?, new: PeerDiscoveryCandidate<Value>?)
}

struct PeerDiscoveryRecoveryTokenStore: Sendable {
    private var changeRevision: UInt = 0
    private var recoveryTokens: [String: String] = [:]

    @discardableResult
    mutating func recordChange(for deviceId: String, browserGeneration: UInt) -> String {
        changeRevision &+= 1
        let token = PeerDiscoveryRecoveryToken.make(
            browserGeneration: browserGeneration,
            changeRevision: changeRevision
        )
        recoveryTokens[deviceId] = token
        return token
    }

    func token(for deviceId: String) -> String? {
        recoveryTokens[deviceId]
    }

    mutating func removeTokensForInactiveDevices(activeDeviceIds: Set<String>) {
        recoveryTokens = recoveryTokens.filter { activeDeviceIds.contains($0.key) }
    }

    mutating func removeAll() {
        changeRevision = 0
        recoveryTokens.removeAll()
    }
}

/// 将完整 Bonjour snapshot 与增量 change 合并成稳定的「每设备一个选中候选」。
/// 同一设备原 selected 仍活跃时保持不变；切换候选或收到 added/changed 时推进该设备 token。
struct PeerDiscoverySnapshotReducer<Value: Hashable & Sendable>: Sendable {
    typealias Candidate = PeerDiscoveryCandidate<Value>
    typealias Change = PeerDiscoveryCandidateChange<Value>

    struct Selection: Equatable, Sendable {
        let deviceId: String
        let candidate: Candidate
        let recoveryToken: String
    }

    private var selectedCandidates: [String: Candidate] = [:]
    private var recoveryTokens = PeerDiscoveryRecoveryTokenStore()

    mutating func reduce(snapshot: [Candidate],
                         changes: [Change],
                         browserGeneration: UInt) -> [Selection] {
        var candidatesByDevice: [String: [Candidate]] = [:]
        var deviceOrder: [String] = []
        for candidate in snapshot {
            if candidatesByDevice[candidate.deviceId] == nil {
                deviceOrder.append(candidate.deviceId)
            }
            candidatesByDevice[candidate.deviceId, default: []].append(candidate)
        }

        var changedNewDevices = Set<String>()
        var removedCandidates = Set<Candidate>()
        for change in changes {
            switch change {
            case let .added(candidate):
                changedNewDevices.insert(candidate.deviceId)
            case let .removed(candidate):
                removedCandidates.insert(candidate)
            case let .changed(old, new):
                if let old {
                    removedCandidates.insert(old)
                }
                if let new {
                    changedNewDevices.insert(new.deviceId)
                }
            }
        }

        var nextSelected: [String: Candidate] = [:]
        for deviceId in deviceOrder {
            guard let candidates = candidatesByDevice[deviceId],
                  let first = candidates.first else { continue }

            let oldSelection = selectedCandidates[deviceId]
            let newSelection: Candidate
            if let oldSelection, candidates.contains(oldSelection) {
                newSelection = oldSelection
            } else {
                newSelection = first
            }
            nextSelected[deviceId] = newSelection

            let selectionChanged = oldSelection != newSelection
            let selectedCandidateWasRemoved = oldSelection.map(removedCandidates.contains) ?? false
            if recoveryTokens.token(for: deviceId) == nil
                || selectionChanged
                || selectedCandidateWasRemoved
                || changedNewDevices.contains(deviceId) {
                recoveryTokens.recordChange(
                    for: deviceId,
                    browserGeneration: browserGeneration
                )
            }
        }

        selectedCandidates = nextSelected
        let activeDeviceIds = Set(nextSelected.keys)
        recoveryTokens.removeTokensForInactiveDevices(activeDeviceIds: activeDeviceIds)

        return deviceOrder.compactMap { deviceId in
            guard let candidate = nextSelected[deviceId],
                  let token = recoveryTokens.token(for: deviceId) else { return nil }
            return Selection(
                deviceId: deviceId,
                candidate: candidate,
                recoveryToken: token
            )
        }
    }

    func recoveryToken(for deviceId: String) -> String? {
        recoveryTokens.token(for: deviceId)
    }

    mutating func reset() {
        selectedCandidates.removeAll()
        recoveryTokens.removeAll()
    }
}

struct PeerDiscoveryLifecycleState: Sendable {
    private(set) var generation: UInt = 0
    private(set) var isBrowsing = false

    mutating func beginBrowsing() -> UInt {
        generation &+= 1
        isBrowsing = true
        return generation
    }

    mutating func invalidateBrowsing() {
        generation &+= 1
        isBrowsing = false
    }

    func accepts(updateGeneration: UInt) -> Bool {
        PeerDiscoveryGenerationGate.accepts(
            updateGeneration: updateGeneration,
            currentGeneration: generation,
            isBrowsing: isBrowsing
        )
    }
}

/// callbacks 由锁保护，可从任意线程配置；consumer 只会由 delivery bridge 在 main queue 调用。
final class PeerDiscoveryCallbackStore: @unchecked Sendable {
    typealias PeersChanged = ([DiscoveredPeer]) -> Void
    typealias Failure = (Error) -> Void

    /// 快照跨 discovery queue → main queue 搬运。其闭包不是 Sendable、也不承诺可在任意队列执行；
    /// 唯一 consumer 是 PeerDiscoveryCallbackDelivery，且只在 main queue 调用它们。
    struct Snapshot: @unchecked Sendable {
        let onPeersChanged: PeersChanged?
        let onFailure: Failure?
    }

    private let lock = NSLock()
    private var peersChangedStorage: PeersChanged?
    private var failureStorage: Failure?

    var onPeersChanged: PeersChanged? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return peersChangedStorage
        }
        set {
            lock.lock()
            peersChangedStorage = newValue
            lock.unlock()
        }
    }

    var onFailure: Failure? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return failureStorage
        }
        set {
            lock.lock()
            failureStorage = newValue
            lock.unlock()
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            onPeersChanged: peersChangedStorage,
            onFailure: failureStorage
        )
    }
}

/// 将 discovery queue 产出的不可变事件按 FIFO 投递到 main queue。
/// bridge 无可变状态；Snapshot 的 unchecked 边界只用于搬运，consumer 永不在 discovery queue 执行。
struct PeerDiscoveryCallbackDelivery: Sendable {
    enum Event: Sendable {
        case peers([DiscoveredPeer])
        case failure(any Error)
    }

    func deliver(_ events: [Event],
                 to callbacks: PeerDiscoveryCallbackStore.Snapshot) {
        DispatchQueue.main.async {
            for event in events {
                switch event {
                case let .peers(peers):
                    callbacks.onPeersChanged?(peers)
                case let .failure(error):
                    callbacks.onFailure?(error)
                }
            }
        }
    }
}

/// Bonjour 浏览 _easysign-transfer._tcp,产出 DiscoveredPeer 列表(已过滤自己)。
/// `@unchecked Sendable` 的依据：browser/lifecycle/reducer/snapshot 只在私有串行 queue 访问；
/// 跨线程 callback 配置由 PeerDiscoveryCallbackStore 的锁单独保护。
final class PeerDiscovery: @unchecked Sendable {
    static let serviceType = "_easysign-transfer._tcp"

    private let queue = DispatchQueue(label: "transfer.discovery")
    private let selfDeviceId: () -> String
    private let callbacks = PeerDiscoveryCallbackStore()
    private let callbackDelivery = PeerDiscoveryCallbackDelivery()

    // 以下状态只允许在 queue 上访问。
    private var browser: NWBrowser?
    private var lifecycle = PeerDiscoveryLifecycleState()
    private var reducer = PeerDiscoverySnapshotReducer<NWBrowser.Result>()
    private var peerSnapshot: [DiscoveredPeer] = []

    /// 可从任意线程配置；setter/getter 经锁同步，回调统一在 main queue 执行。
    var onPeersChanged: (([DiscoveredPeer]) -> Void)? {
        get { callbacks.onPeersChanged }
        set { callbacks.onPeersChanged = newValue }
    }

    /// 可从任意线程配置；setter/getter 经锁同步，回调统一在 main queue 执行。
    var onFailure: ((Error) -> Void)? {
        get { callbacks.onFailure }
        set { callbacks.onFailure = newValue }
    }

    init(selfDeviceId: @escaping () -> String) {
        self.selfDeviceId = selfDeviceId
    }

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    private func startOnQueue() {
        let browserGeneration = lifecycle.beginBrowsing()
        browser?.cancel()
        browser = nil

        let hadPeers = !peerSnapshot.isEmpty
        clearRecoveryState()
        if hadPeers {
            publishPeers([])
        }

        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
            using: params
        )
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self, weak browser] results, changes in
            guard let self, let browser else { return }
            self.handleResults(
                results,
                changes: changes,
                browser: browser,
                updateGeneration: browserGeneration
            )
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser else { return }
            self.handleState(
                state,
                browser: browser,
                updateGeneration: browserGeneration
            )
        }
        browser.start(queue: queue)
    }

    private func stopOnQueue() {
        lifecycle.invalidateBrowsing()
        browser?.cancel()
        browser = nil

        let hadPeers = !peerSnapshot.isEmpty
        clearRecoveryState()
        if hadPeers {
            publishPeers([])
        }
    }

    private func handleResults(_ results: Set<NWBrowser.Result>,
                               changes: Set<NWBrowser.Result.Change>,
                               browser: NWBrowser,
                               updateGeneration: UInt) {
        guard lifecycle.accepts(updateGeneration: updateGeneration),
              self.browser === browser else { return }

        let candidates = results.compactMap(candidate(for:))
        let candidateChanges = changes.compactMap(candidateChange(for:))
        let selections = reducer.reduce(
            snapshot: candidates,
            changes: candidateChanges,
            browserGeneration: updateGeneration
        )

        peerSnapshot = selections.compactMap { selection in
            makePeer(
                from: selection.candidate.value,
                recoveryToken: selection.recoveryToken
            )
        }
        publishPeers(peerSnapshot)
    }

    private func candidate(for result: NWBrowser.Result) -> PeerDiscoveryCandidate<NWBrowser.Result>? {
        guard case let .bonjour(txt) = result.metadata else { return nil }
        let deviceId = txt["deviceId"] ?? ""
        guard !deviceId.isEmpty, deviceId != selfDeviceId() else { return nil }
        return PeerDiscoveryCandidate(value: result, deviceId: deviceId)
    }

    private func candidateChange(for change: NWBrowser.Result.Change)
        -> PeerDiscoveryCandidateChange<NWBrowser.Result>? {
        switch change {
        case let .added(result):
            return candidate(for: result).map(PeerDiscoveryCandidateChange.added)
        case let .removed(result):
            return candidate(for: result).map(PeerDiscoveryCandidateChange.removed)
        case let .changed(old, new, _):
            let oldCandidate = candidate(for: old)
            let newCandidate = candidate(for: new)
            guard oldCandidate != nil || newCandidate != nil else { return nil }
            return .changed(old: oldCandidate, new: newCandidate)
        case .identical:
            return nil
        @unknown default:
            return nil
        }
    }

    private func makePeer(from result: NWBrowser.Result,
                          recoveryToken: String) -> DiscoveredPeer? {
        guard case let .bonjour(txt) = result.metadata else { return nil }
        let deviceId = txt["deviceId"] ?? ""
        guard !deviceId.isEmpty, deviceId != selfDeviceId() else { return nil }
        return DiscoveredPeer(
            deviceId: deviceId,
            name: txt["name"] ?? deviceId,
            fingerprint: txt["fp"] ?? "",
            endpoint: result.endpoint,
            recoveryToken: recoveryToken
        )
    }

    private func handleState(_ state: NWBrowser.State,
                             browser: NWBrowser,
                             updateGeneration: UInt) {
        guard lifecycle.accepts(updateGeneration: updateGeneration),
              self.browser === browser else { return }
        guard case let .failed(error) = state else { return }

        // 先失效 generation，再取消/清空；回调重入 start/stop 时只会排到本次原子清理之后。
        lifecycle.invalidateBrowsing()
        browser.cancel()
        self.browser = nil
        clearRecoveryState()

        let callbackSnapshot = callbacks.snapshot()
        callbackDelivery.deliver(
            [.peers([]), .failure(error)],
            to: callbackSnapshot
        )
    }

    private func clearRecoveryState() {
        reducer.reset()
        peerSnapshot.removeAll()
    }

    private func publishPeers(_ peers: [DiscoveredPeer]) {
        callbackDelivery.deliver(
            [.peers(peers)],
            to: callbacks.snapshot()
        )
    }

    /// 按 deviceId 去重,保留首次出现的那条。纯函数,便于单测及兼容既有调用。
    static func deduped(_ peers: [DiscoveredPeer]) -> [DiscoveredPeer] {
        var seen = Set<String>()
        return peers.filter { seen.insert($0.deviceId).inserted }
    }
}
