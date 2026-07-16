import Foundation
import Network

struct TransferTrustedEndpoint: Equatable, Sendable {
    let peer: TransferAutoReconnect.PeerRef
    let host: String
    let port: UInt16

    var reconnectEndpointKey: String {
        "trusted:\(peer.deviceId):\(host):\(port)"
    }

    static func host(from endpoint: NWEndpoint) -> String? {
        switch endpoint {
        case .hostPort(let host, _):
            String(describing: host)
        case .url(let url):
            url.host
        default:
            nil
        }
    }
}

enum TransferAutomaticTarget {
    case bonjour(DiscoveredPeer)
    case trusted(TransferTrustedEndpoint, peerName: String)

    var peerRef: TransferAutoReconnect.PeerRef {
        switch self {
        case .bonjour(let peer):
            TransferAutoReconnect.PeerRef(
                deviceId: peer.deviceId,
                fingerprint: peer.fingerprint
            )
        case .trusted(let endpoint, peerName: _):
            endpoint.peer
        }
    }

    var reconnectEndpointKey: String {
        switch self {
        case .bonjour(let peer):
            peer.reconnectEndpointKey
        case .trusted(let endpoint, peerName: _):
            endpoint.reconnectEndpointKey
        }
    }

    var displayName: String {
        switch self {
        case .bonjour(let peer):
            peer.name
        case .trusted(_, let peerName):
            peerName
        }
    }
}
