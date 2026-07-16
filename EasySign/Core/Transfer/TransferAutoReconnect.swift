import Foundation
import Network

/// 互传「自动(免码)重连」的纯决策逻辑。抽成无副作用的函数便于单测:
/// 不读任何可变服务状态、不碰网络 / 钥匙串 / 通知中心。
///
/// 设计:已配对设备重连靠 TLS 证书指纹固定(pinning),不需要配对码;
/// 故自动重连一律走免码路径,永远不碰那个会在每次配对成功后轮换的 pendingPairingCode。
enum TransferAutoReconnect {
    /// 一台对端的稳定标识(配对时确定,跨会话不变)。
    struct PeerRef: Hashable, Sendable {
        let deviceId: String
        let fingerprint: String
    }

    /// 从最新 Bonjour 快照或已保存的可信地址中选择自动重连目标。
    /// 所有身份、配对和单向拨号门禁都先于端点选择执行，可信地址不能绕过既有仲裁。
    static func target(busy: Bool,
                       userStopped: Bool,
                       selfDeviceId: String,
                       last: PeerRef?,
                       discovered: [DiscoveredPeer],
                       trusted: [PeerRef: TransferTrustedEndpoint],
                       pairedPeers: [PairedPeer]) -> TransferAutomaticTarget? {
        guard !busy, !userStopped, let last else { return nil }
        guard let pairedPeer = pairedPeers.first(where: {
            $0.deviceId == last.deviceId && $0.fingerprint == last.fingerprint
        }) else { return nil }
        guard selfDeviceId < last.deviceId else { return nil }

        if let peer = discovered.first(where: {
            $0.deviceId == last.deviceId && $0.fingerprint == last.fingerprint
        }) {
            return .bonjour(peer)
        }

        guard let endpoint = trusted[last], endpoint.peer == last else { return nil }
        return .trusted(endpoint, peerName: pairedPeer.name)
    }
}
