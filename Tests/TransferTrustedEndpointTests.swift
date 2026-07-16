import Foundation

/// Compile and run:
/// swiftc -swift-version 5 -module-cache-path /tmp/easysign-swift-module-cache \
///   EasySign/Core/Transfer/TransferModels.swift \
///   EasySign/Core/Transfer/TransferAutoReconnect.swift \
///   EasySign/Core/Transfer/TransferTrustedEndpoint.swift \
///   Tests/TransferTrustedEndpointTests.swift -o /tmp/transfer-trusted-endpoint \
///   && /tmp/transfer-trusted-endpoint

@main
struct TransferTrustedEndpointTests {
    static func main() {
        let peer = TransferAutoReconnect.PeerRef(deviceId: "B", fingerprint: "fp-B")
        let original = TransferTrustedEndpoint(peer: peer, host: "10.0.0.8", port: 54321)
        let same = TransferTrustedEndpoint(peer: peer, host: "10.0.0.8", port: 54321)
        let changedHost = TransferTrustedEndpoint(peer: peer, host: "10.0.0.9", port: 54321)
        let changedPort = TransferTrustedEndpoint(peer: peer, host: "10.0.0.8", port: 54322)

        expect(original.reconnectEndpointKey == same.reconnectEndpointKey,
               "同一 peer、host、port 应生成稳定的 endpoint key")
        expect(original.reconnectEndpointKey != changedHost.reconnectEndpointKey,
               "host 改变时 endpoint key 应改变")
        expect(original.reconnectEndpointKey != changedPort.reconnectEndpointKey,
               "port 改变时 endpoint key 应改变")

        print("ALL PASS")
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }
}
