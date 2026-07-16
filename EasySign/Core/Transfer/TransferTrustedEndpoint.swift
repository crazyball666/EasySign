struct TransferTrustedEndpoint: Equatable, Sendable {
    let peer: TransferAutoReconnect.PeerRef
    let host: String
    let port: UInt16

    var reconnectEndpointKey: String {
        "trusted:\(peer.deviceId):\(host):\(port)"
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
