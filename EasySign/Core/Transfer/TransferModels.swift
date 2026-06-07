import Foundation
import Network

// Renamed PeerTransferKind to avoid collision with the device-sync TransferKind
// in EasySign/Features/Devices/TransferProgressBar.swift.
enum PeerTransferKind: String, Codable { case text, image, file }

enum TransferDirection: String, Codable { case incoming, outgoing }

struct TransferItem: Identifiable, Equatable, Codable {
    let id: UUID
    let kind: PeerTransferKind
    let direction: TransferDirection
    let timestamp: Date
    let preview: String
    var peerName: String
    /// 收到的文件/图片落盘后的本地路径,供后续打开。文本类为 nil。
    var localURL: URL?

    init(id: UUID = UUID(), kind: PeerTransferKind, direction: TransferDirection,
         timestamp: Date = Date(), preview: String, peerName: String, localURL: URL? = nil) {
        self.id = id; self.kind = kind; self.direction = direction
        self.timestamp = timestamp; self.preview = preview; self.peerName = peerName
        self.localURL = localURL
    }
}

struct PairedPeer: Codable, Identifiable, Equatable {
    var id: String { deviceId }
    let deviceId: String
    var name: String
    let fingerprint: String
}

enum ConnectionState: Equatable {
    case idle
    case connecting
    case pairing
    case connected(peerName: String)
    case failed(String)
}

/// Bonjour 浏览发现的一台对端设备。fingerprint 来自 TXT 记录,用于标注是否已配对。
struct DiscoveredPeer: Identifiable, Equatable {
    var id: String { deviceId }
    let deviceId: String
    let name: String
    let fingerprint: String     // 对端证书指纹(来自 TXT),用于标注已配对
    let endpoint: NWEndpoint
    static func == (l: DiscoveredPeer, r: DiscoveredPeer) -> Bool {
        l.deviceId == r.deviceId && l.fingerprint == r.fingerprint
    }
}
