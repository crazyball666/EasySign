import Foundation

enum TransferReconnectHintPolicy {
    static func endpoint(
        peer: TransferAutoReconnect.PeerRef,
        sourceIsActive: Bool,
        remoteHost: String?,
        port: UInt16
    ) -> TransferTrustedEndpoint? {
        guard sourceIsActive,
              let host = remoteHost?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty,
              port != 0
        else { return nil }

        return TransferTrustedEndpoint(peer: peer, host: host, port: port)
    }
}
