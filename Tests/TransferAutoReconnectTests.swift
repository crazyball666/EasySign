import Foundation
import Network

/// 坐实互传「自动(免码)重连」的决策规则 TransferAutoReconnect.target:
/// 只在「空闲 + 非用户主动断开 + 记得最后那台且它已配对并正被 Bonjour 发现」时才返回要连的对端。
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
        let pairedA: Set<String> = ["fa"]
        // 本机 id「较小」(< "A")时才主动拨号;多数用例用它以便走到正常分支。
        let lo = "0-self"   // '0' < 'A',本机为发起方
        let hi = "z-self"   // 'z' > 'A',本机应等待对端发起

        // 1. 满足全部条件 + 本机 id 较小 → 返回该对端
        let hit = TransferAutoReconnect.target(busy: false, userStopped: false, selfDeviceId: lo, last: last,
                                               discovered: discoveredA, pairedFingerprints: pairedA)
        expect(hit?.deviceId == "A", "正常情况应返回 A,实际 \(String(describing: hit?.deviceId))")

        // 2. 忙(已连接/连接中/配对中)→ 不重连
        expect(TransferAutoReconnect.target(busy: true, userStopped: false, selfDeviceId: lo, last: last,
                                            discovered: discoveredA, pairedFingerprints: pairedA) == nil,
               "busy 时不应重连")

        // 3. 用户主动断开 → 不重连
        expect(TransferAutoReconnect.target(busy: false, userStopped: true, selfDeviceId: lo, last: last,
                                            discovered: discoveredA, pairedFingerprints: pairedA) == nil,
               "userStopped 时不应重连")

        // 4. 没有「最后那台」记忆 → 不重连
        expect(TransferAutoReconnect.target(busy: false, userStopped: false, selfDeviceId: lo, last: nil,
                                            discovered: discoveredA, pairedFingerprints: pairedA) == nil,
               "last == nil 时不应重连")

        // 5. 最后那台已不在已配对列表(被清过配对)→ 不重连
        expect(TransferAutoReconnect.target(busy: false, userStopped: false, selfDeviceId: lo, last: last,
                                            discovered: discoveredA, pairedFingerprints: []) == nil,
               "对端不在已配对列表时不应重连")

        // 6. 最后那台此刻没被发现 → 不重连
        expect(TransferAutoReconnect.target(busy: false, userStopped: false, selfDeviceId: lo, last: last,
                                            discovered: [peer("B", "fb")], pairedFingerprints: pairedA) == nil,
               "对端未被发现时不应重连")

        // 7. 同 deviceId 但指纹不符(对端换了身份)→ 不重连,避免连到冒名者
        expect(TransferAutoReconnect.target(busy: false, userStopped: false, selfDeviceId: lo, last: last,
                                            discovered: [peer("A", "fX")], pairedFingerprints: pairedA) == nil,
               "deviceId 同但指纹不符时不应重连")

        // 8. 多台在线时,只挑「最后那台」
        let many = [peer("B", "fb"), peer("A", "fa", name: "MacA"), peer("C", "fc")]
        let pickMany = TransferAutoReconnect.target(busy: false, userStopped: false, selfDeviceId: lo, last: last,
                                                    discovered: many, pairedFingerprints: ["fa", "fb", "fc"])
        expect(pickMany?.deviceId == "A", "多台在线应只挑 A,实际 \(String(describing: pickMany?.deviceId))")

        // 9. 单向拨号仲裁:本机 id 较大(> 对端)→ 不主动拨号,等待对端发起(否则两端互拨抖动)
        expect(TransferAutoReconnect.target(busy: false, userStopped: false, selfDeviceId: hi, last: last,
                                            discovered: discoveredA, pairedFingerprints: pairedA) == nil,
               "本机 id 较大时应等待对端发起,不主动拨号")

        print("ALL PASS")
    }

    static func expect(_ c: Bool, _ m: String) {
        if !c {
            FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8))
            exit(1)
        }
    }
}
