import Foundation
import Network

/// Compile and run:
/// swiftc -swift-version 5 -module-cache-path /tmp/easysign-swift-module-cache \
///   EasySign/Core/Transfer/TransferModels.swift \
///   EasySign/Core/Transfer/TransferAutoReconnect.swift \
///   EasySign/Core/Transfer/TransferTrustedEndpoint.swift \
///   EasySign/Core/Transfer/TransferReconnectHintPolicy.swift \
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

        let ipv4 = NWEndpoint.hostPort(host: "10.0.0.8", port: 5000)
        expect(TransferTrustedEndpoint.host(from: ipv4) == "10.0.0.8",
               "hostPort 应提取 IPv4 host")
        let ipv6 = NWEndpoint.hostPort(host: "2001:db8::8", port: 5000)
        expect(TransferTrustedEndpoint.host(from: ipv6) == "2001:db8::8",
               "hostPort 应完整保留 IPv6 host")
        let url = NWEndpoint.url(URL(string: "ws://10.0.0.9:5000/transfer")!)
        expect(TransferTrustedEndpoint.host(from: url) == "10.0.0.9",
               "URL endpoint 应提取 host")
        let service = NWEndpoint.service(
            name: "peer-B",
            type: "_easysign-transfer._tcp",
            domain: "local.",
            interface: nil
        )
        expect(TransferTrustedEndpoint.host(from: service) == nil,
               "Bonjour service endpoint 不得用作安全直连 host")

        expect(TransferReconnectHintPolicy.endpoint(
            peer: peer,
            sourceIsActive: false,
            remoteHost: "10.0.0.8",
            port: 5000
        ) == nil, "旧 source 的 hint 必须忽略")
        expect(TransferReconnectHintPolicy.endpoint(
            peer: peer,
            sourceIsActive: true,
            remoteHost: "10.0.0.8",
            port: 5000
        ) == TransferTrustedEndpoint(peer: peer, host: "10.0.0.8", port: 5000),
        "active source 的有效 hint 应绑定同一 PeerRef")
        expect(TransferReconnectHintPolicy.endpoint(
            peer: peer,
            sourceIsActive: true,
            remoteHost: "",
            port: 5000
        ) == nil, "空 host 必须拒绝")
        expect(TransferReconnectHintPolicy.endpoint(
            peer: peer,
            sourceIsActive: true,
            remoteHost: "   \t\n",
            port: 5000
        ) == nil, "全空白 host 必须拒绝")
        expect(TransferReconnectHintPolicy.endpoint(
            peer: peer,
            sourceIsActive: true,
            remoteHost: "10.0.0.8",
            port: 0
        ) == nil, "port 0 必须拒绝")

        print("ALL PASS")
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }
}
