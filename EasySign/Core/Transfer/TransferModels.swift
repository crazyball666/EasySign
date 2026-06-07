import Foundation

// Renamed PeerTransferKind to avoid collision with the device-sync TransferKind
// in EasySign/Features/Devices/TransferProgressBar.swift.
enum PeerTransferKind: String, Codable { case text, image, file }

enum TransferDirection: String, Codable { case incoming, outgoing }

struct TransferItem: Identifiable, Equatable {
    let id: UUID
    let kind: PeerTransferKind
    let direction: TransferDirection
    let timestamp: Date
    let preview: String
    var peerName: String

    init(id: UUID = UUID(), kind: PeerTransferKind, direction: TransferDirection,
         timestamp: Date = Date(), preview: String, peerName: String) {
        self.id = id; self.kind = kind; self.direction = direction
        self.timestamp = timestamp; self.preview = preview; self.peerName = peerName
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
