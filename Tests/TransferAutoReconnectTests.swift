import Foundation
import Network

/// 坐实互传「自动(免码)重连」的决策规则 TransferAutoReconnect.target:
/// 只在「空闲 + 非用户主动断开 + 记得最后那台且它仍已配对」时，
/// 才返回 Bonjour 优先、可信直连回退的统一生产目标。
///
/// 期望输出:`ALL PASS`,否则 `FAIL: ...` 到 stderr + exit(1)。

@main
struct TransferAutoReconnectTests {
    static let ep = NWEndpoint.hostPort(host: "127.0.0.1", port: 5000)

    static func peer(_ id: String, _ fp: String, name: String = "Mac") -> DiscoveredPeer {
        DiscoveredPeer(deviceId: id, name: name, fingerprint: fp, endpoint: ep)
    }

    static func main() {
        let last = TransferAutoReconnect.PeerRef(deviceId: "A", fingerprint: "fa")
        let discoveredA = [peer("A", "fa", name: "MacA")]
        let pairedA = [PairedPeer(deviceId: "A", name: "MacA", fingerprint: "fa")]
        // 本机 id「较小」(< "A")时才主动拨号;多数用例用它以便走到正常分支。
        let lo = "0-self"   // '0' < 'A',本机为发起方
        let hi = "z-self"   // 'z' > 'A',本机应等待对端发起

        // 1. 满足全部条件 + 本机 id 较小 → 返回该对端
        let hit = TransferAutoReconnect.target(busy: false, userStopped: false, selfDeviceId: lo, last: last,
                                               discovered: discoveredA, trusted: [:], pairedPeers: pairedA)
        expect(hit?.peerRef.deviceId == "A",
               "正常情况应返回 A,实际 \(String(describing: hit?.peerRef.deviceId))")

        // 2. 忙(已连接/连接中/配对中)→ 不重连
        expect(TransferAutoReconnect.target(busy: true, userStopped: false, selfDeviceId: lo, last: last,
                                            discovered: discoveredA, trusted: [:], pairedPeers: pairedA) == nil,
               "busy 时不应重连")

        // 3. 用户主动断开 → 不重连
        expect(TransferAutoReconnect.target(busy: false, userStopped: true, selfDeviceId: lo, last: last,
                                            discovered: discoveredA, trusted: [:], pairedPeers: pairedA) == nil,
               "userStopped 时不应重连")

        // 4. 没有「最后那台」记忆 → 不重连
        expect(TransferAutoReconnect.target(busy: false, userStopped: false, selfDeviceId: lo, last: nil,
                                            discovered: discoveredA, trusted: [:], pairedPeers: pairedA) == nil,
               "last == nil 时不应重连")

        // 5. 最后那台已不在已配对列表(被清过配对)→ 不重连
        expect(TransferAutoReconnect.target(busy: false, userStopped: false, selfDeviceId: lo, last: last,
                                            discovered: discoveredA, trusted: [:], pairedPeers: []) == nil,
               "对端不在已配对列表时不应重连")

        // 6. 最后那台此刻没被发现 → 不重连
        expect(TransferAutoReconnect.target(busy: false, userStopped: false, selfDeviceId: lo, last: last,
                                            discovered: [peer("B", "fb")], trusted: [:], pairedPeers: pairedA) == nil,
               "对端未被发现时不应重连")

        // 7. 同 deviceId 但指纹不符(对端换了身份)→ 不重连,避免连到冒名者
        expect(TransferAutoReconnect.target(busy: false, userStopped: false, selfDeviceId: lo, last: last,
                                            discovered: [peer("A", "fX")], trusted: [:], pairedPeers: pairedA) == nil,
               "deviceId 同但指纹不符时不应重连")

        // 8. 多台在线时,只挑「最后那台」
        let many = [peer("B", "fb"), peer("A", "fa", name: "MacA"), peer("C", "fc")]
        let pickMany = TransferAutoReconnect.target(busy: false, userStopped: false, selfDeviceId: lo, last: last,
                                                    discovered: many, trusted: [:], pairedPeers: pairedA)
        expect(pickMany?.peerRef.deviceId == "A",
               "多台在线应只挑 A,实际 \(String(describing: pickMany?.peerRef.deviceId))")

        // 9. 单向拨号仲裁:本机 id 较大(> 对端)→ 不主动拨号,等待对端发起(否则两端互拨抖动 glare)
        expect(TransferAutoReconnect.target(busy: false, userStopped: false, selfDeviceId: hi, last: last,
                                            discovered: discoveredA, trusted: [:], pairedPeers: pairedA) == nil,
               "本机 id 较大时应等待对端发起,不主动拨号")

        // 10. Bonjour 缺失时可回退到已配对对端的可信地址。
        let trustedPeer = TransferAutoReconnect.PeerRef(deviceId: "B", fingerprint: "fp-B")
        let trusted = TransferTrustedEndpoint(peer: trustedPeer, host: "10.0.0.8", port: 54321)
        let pairedB = [PairedPeer(deviceId: "B", name: "Mac B", fingerprint: "fp-B")]
        let fallback = TransferAutoReconnect.target(
            busy: false,
            userStopped: false,
            selfDeviceId: "A",
            last: trustedPeer,
            discovered: [],
            trusted: [trustedPeer: trusted],
            pairedPeers: pairedB
        )
        expect(fallback?.reconnectEndpointKey == trusted.reconnectEndpointKey,
               "Bonjour 缺失时应回退可信地址")
        expect(fallback?.peerRef == trustedPeer, "可信目标应保留完整 peer 身份")
        expect(fallback?.displayName == "Mac B", "可信目标应使用已配对设备名称")

        // 11. 同一身份同时有 Bonjour 与可信地址时，优先使用最新 Bonjour 端点。
        let bonjourB = peer("B", "fp-B", name: "Bonjour Mac B")
        let preferred = TransferAutoReconnect.target(
            busy: false,
            userStopped: false,
            selfDeviceId: "A",
            last: trustedPeer,
            discovered: [bonjourB],
            trusted: [trustedPeer: trusted],
            pairedPeers: pairedB
        )
        expect(preferred?.reconnectEndpointKey == bonjourB.reconnectEndpointKey,
               "匹配身份的 Bonjour 应优先于可信地址")
        expect(preferred?.peerRef == trustedPeer, "Bonjour 目标应提供 deviceId 与 fingerprint 身份")
        expect(preferred?.displayName == "Bonjour Mac B", "Bonjour 目标应保留发现名称")

        // 12. 可信地址不能绕过既有门禁与单向拨号仲裁。
        expect(TransferAutoReconnect.target(
            busy: true, userStopped: false, selfDeviceId: "A", last: trustedPeer,
            discovered: [], trusted: [trustedPeer: trusted], pairedPeers: pairedB
        ) == nil, "busy 时可信地址不应触发重连")
        expect(TransferAutoReconnect.target(
            busy: false, userStopped: true, selfDeviceId: "A", last: trustedPeer,
            discovered: [], trusted: [trustedPeer: trusted], pairedPeers: pairedB
        ) == nil, "userStopped 时可信地址不应触发重连")
        expect(TransferAutoReconnect.target(
            busy: false, userStopped: false, selfDeviceId: "A", last: nil,
            discovered: [], trusted: [trustedPeer: trusted], pairedPeers: pairedB
        ) == nil, "last == nil 时可信地址不应触发重连")
        expect(TransferAutoReconnect.target(
            busy: false, userStopped: false, selfDeviceId: "A", last: trustedPeer,
            discovered: [], trusted: [trustedPeer: trusted], pairedPeers: []
        ) == nil, "未配对时可信地址不应触发重连")
        expect(TransferAutoReconnect.target(
            busy: false, userStopped: false, selfDeviceId: "A", last: trustedPeer,
            discovered: [], trusted: [trustedPeer: trusted],
            pairedPeers: [PairedPeer(deviceId: "B", name: "Mac B", fingerprint: "fp-X")]
        ) == nil, "配对指纹错误时可信地址不应触发重连")
        expect(TransferAutoReconnect.target(
            busy: false, userStopped: false, selfDeviceId: "A", last: trustedPeer,
            discovered: [], trusted: [trustedPeer: trusted],
            pairedPeers: [PairedPeer(deviceId: "C", name: "Mac C", fingerprint: "fp-B")]
        ) == nil, "配对 deviceId 错误时可信地址不应触发重连")
        let wrongFingerprintPeer = TransferAutoReconnect.PeerRef(deviceId: "B", fingerprint: "fp-X")
        let wrongFingerprintEndpoint = TransferTrustedEndpoint(
            peer: wrongFingerprintPeer, host: "10.0.0.8", port: 54321
        )
        expect(TransferAutoReconnect.target(
            busy: false, userStopped: false, selfDeviceId: "A", last: trustedPeer,
            discovered: [], trusted: [trustedPeer: wrongFingerprintEndpoint], pairedPeers: pairedB
        ) == nil, "可信地址的 fingerprint 错误时不应触发重连")
        let wrongDevicePeer = TransferAutoReconnect.PeerRef(deviceId: "C", fingerprint: "fp-B")
        let wrongDeviceEndpoint = TransferTrustedEndpoint(
            peer: wrongDevicePeer, host: "10.0.0.8", port: 54321
        )
        expect(TransferAutoReconnect.target(
            busy: false, userStopped: false, selfDeviceId: "A", last: trustedPeer,
            discovered: [], trusted: [trustedPeer: wrongDeviceEndpoint], pairedPeers: pairedB
        ) == nil, "可信地址的 deviceId 错误时不应触发重连")
        expect(TransferAutoReconnect.target(
            busy: false, userStopped: false, selfDeviceId: "Z", last: trustedPeer,
            discovered: [], trusted: [trustedPeer: trusted], pairedPeers: pairedB
        ) == nil, "本机 deviceId 较大时可信地址也必须等待入站")

        print("ALL PASS")
    }

    static func expect(_ c: Bool, _ m: String) {
        if !c {
            FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8))
            exit(1)
        }
    }
}
