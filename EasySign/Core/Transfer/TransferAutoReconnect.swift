import Foundation
import Network

/// 互传「自动(免码)重连」的纯决策逻辑。抽成无副作用的函数便于单测:
/// 不读任何可变服务状态、不碰网络 / 钥匙串 / 通知中心。
///
/// 设计:已配对设备重连靠 TLS 证书指纹固定(pinning),不需要配对码;
/// 故自动重连一律走免码路径,永远不碰那个会在每次配对成功后轮换的 pendingPairingCode。
enum TransferAutoReconnect {
    /// 一台对端的稳定标识(配对时确定,跨会话不变)。
    struct PeerRef: Equatable {
        let deviceId: String
        let fingerprint: String
    }

    /// 当前状态下应自动免码重连到哪台对端;`nil` = 不重连。
    ///
    /// 全部满足才重连:
    /// - `!busy`:当前空闲(非已连接 / 连接中 / 配对中)
    /// - `!userStopped`:不是用户主动点了「断开」
    /// - `last != nil`:记得「最后一次成功连上的那台」
    /// - 该对端指纹仍在已配对列表(`pairedFingerprints`)里
    /// - 该对端此刻正被 Bonjour 发现到(deviceId + 指纹都对得上)
    /// - `selfDeviceId < peer.deviceId`:确定性单向拨号仲裁。对端重新出现时两端都会评估本函数,
    ///   若都拨号会产生两条连接互相顶替而抖动;故只让「本机 id 较小」的一端发起,另一端走入站 accept。
    ///   (deviceId 全局唯一不相等,故恰有一端通过。转瞬抖动仍由各自出站的 scheduleReconnect 兜底,与此无关。)
    static func target(busy: Bool,
                       userStopped: Bool,
                       selfDeviceId: String,
                       last: PeerRef?,
                       discovered: [DiscoveredPeer],
                       pairedFingerprints: Set<String>) -> DiscoveredPeer? {
        guard !busy, !userStopped, let last else { return nil }
        guard pairedFingerprints.contains(last.fingerprint) else { return nil }
        guard let peer = discovered.first(where: { $0.deviceId == last.deviceId && $0.fingerprint == last.fingerprint })
        else { return nil }
        guard selfDeviceId < peer.deviceId else { return nil }   // 单向拨号:本机 id 较大则等待对端发起
        return peer
    }
}
