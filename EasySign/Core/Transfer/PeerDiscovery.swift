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

struct PeerDiscoveryRecoveryTokenStore {
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

/// Bonjour 浏览 _easysign-transfer._tcp,产出 DiscoveredPeer 列表(已过滤自己)。
final class PeerDiscovery {
    static let serviceType = "_easysign-transfer._tcp"

    private let queue = DispatchQueue(label: "transfer.discovery")
    private let selfDeviceId: () -> String

    // 以下状态只允许在 queue 上访问。
    private var browser: NWBrowser?
    private var generation: UInt = 0
    private var recoveryTokenStore = PeerDiscoveryRecoveryTokenStore()
    private var peerSnapshot: [DiscoveredPeer] = []

    /// 发现列表变化回调(主线程外;消费者自行切主线程)。启动后视为不可变配置。
    var onPeersChanged: (([DiscoveredPeer]) -> Void)?
    /// Browser 失败回调(主线程外)。启动后视为不可变配置。
    var onFailure: ((Error) -> Void)?

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
        generation &+= 1
        browser?.cancel()
        browser = nil

        let hadPeers = !peerSnapshot.isEmpty
        clearRecoveryState()
        if hadPeers {
            onPeersChanged?([])
        }

        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
            using: params
        )
        let browserGeneration = generation
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
        generation &+= 1
        browser?.cancel()
        browser = nil

        let hadPeers = !peerSnapshot.isEmpty
        clearRecoveryState()
        if hadPeers {
            onPeersChanged?([])
        }
    }

    private func handleResults(_ results: Set<NWBrowser.Result>,
                               changes: Set<NWBrowser.Result.Change>,
                               browser: NWBrowser,
                               updateGeneration: UInt) {
        guard PeerDiscoveryGenerationGate.accepts(
            updateGeneration: updateGeneration,
            currentGeneration: generation,
            isBrowsing: self.browser === browser
        ) else { return }

        updateRecoveryTokens(
            for: changes,
            activeResults: results,
            browserGeneration: updateGeneration
        )

        let peers = results.compactMap { result -> DiscoveredPeer? in
            guard case let .bonjour(txt) = result.metadata else { return nil }
            let deviceId = txt["deviceId"] ?? ""
            guard !deviceId.isEmpty, deviceId != selfDeviceId() else { return nil }
            let name = txt["name"] ?? deviceId
            let fingerprint = txt["fp"] ?? ""
            return DiscoveredPeer(
                deviceId: deviceId,
                name: name,
                fingerprint: fingerprint,
                endpoint: result.endpoint,
                recoveryToken: recoveryTokenStore.token(for: deviceId)
            )
        }

        peerSnapshot = Self.deduped(peers)
        onPeersChanged?(peerSnapshot)
    }

    private func updateRecoveryTokens(for changes: Set<NWBrowser.Result.Change>,
                                      activeResults: Set<NWBrowser.Result>,
                                      browserGeneration: UInt) {
        for change in changes {
            let result: NWBrowser.Result
            switch change {
            case let .added(added):
                result = added
            case let .changed(_, new, _):
                result = new
            case .identical, .removed:
                continue
            @unknown default:
                continue
            }

            guard let deviceId = relevantDeviceId(for: result) else { continue }
            recoveryTokenStore.recordChange(
                for: deviceId,
                browserGeneration: browserGeneration
            )
        }

        let activeDeviceIds = Set(activeResults.compactMap(relevantDeviceId(for:)))
        recoveryTokenStore.removeTokensForInactiveDevices(activeDeviceIds: activeDeviceIds)
    }

    private func relevantDeviceId(for result: NWBrowser.Result) -> String? {
        guard case let .bonjour(txt) = result.metadata else { return nil }
        let deviceId = txt["deviceId"] ?? ""
        guard !deviceId.isEmpty, deviceId != selfDeviceId() else { return nil }
        return deviceId
    }

    private func handleState(_ state: NWBrowser.State,
                             browser: NWBrowser,
                             updateGeneration: UInt) {
        guard PeerDiscoveryGenerationGate.accepts(
            updateGeneration: updateGeneration,
            currentGeneration: generation,
            isBrowsing: self.browser === browser
        ) else { return }

        guard case let .failed(error) = state else { return }

        generation &+= 1
        browser.cancel()
        self.browser = nil
        clearRecoveryState()
        onPeersChanged?([])
        onFailure?(error)
    }

    private func clearRecoveryState() {
        recoveryTokenStore.removeAll()
        peerSnapshot.removeAll()
    }

    /// 按 deviceId 去重,保留首次出现的那条。纯函数,便于单测。
    static func deduped(_ peers: [DiscoveredPeer]) -> [DiscoveredPeer] {
        var seen = Set<String>()
        return peers.filter { seen.insert($0.deviceId).inserted }
    }
}
