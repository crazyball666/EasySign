import Foundation
import Network

/// Bonjour 浏览 _easysign-transfer._tcp,产出 DiscoveredPeer 列表(已过滤自己)。
final class PeerDiscovery {
    static let serviceType = "_easysign-transfer._tcp"
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "transfer.discovery")
    private let selfDeviceId: () -> String

    /// 发现列表变化回调(主线程外;消费者自行切主线程)。
    var onPeersChanged: (([DiscoveredPeer]) -> Void)?

    init(selfDeviceId: @escaping () -> String) { self.selfDeviceId = selfDeviceId }

    func start() {
        stop()
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handle(results)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() { browser?.cancel(); browser = nil }

    private func handle(_ results: Set<NWBrowser.Result>) {
        var peers: [DiscoveredPeer] = []
        for r in results {
            guard case let .bonjour(txt) = r.metadata else { continue }
            let deviceId = txt["deviceId"] ?? ""
            guard !deviceId.isEmpty, deviceId != selfDeviceId() else { continue }
            let name = txt["name"] ?? deviceId
            let fp = txt["fp"] ?? ""
            peers.append(DiscoveredPeer(deviceId: deviceId, name: name, fingerprint: fp, endpoint: r.endpoint))
        }
        // 同一设备可能经多个接口(Wi-Fi + includePeerToPeer 的 P2P)被发现 → deviceId 重复。
        // 按 deviceId 去重(保留首条),否则 UI ForEach(id: deviceId) 会撞 id。
        onPeersChanged?(Self.deduped(peers))
    }

    /// 按 deviceId 去重,保留首次出现的那条。纯函数,便于单测。
    static func deduped(_ peers: [DiscoveredPeer]) -> [DiscoveredPeer] {
        var seen = Set<String>()
        return peers.filter { seen.insert($0.deviceId).inserted }
    }
}
