import Foundation
import Network

/// 坐实:同一台设备经多个接口(Wi-Fi + P2P)被 Bonjour 发现时,会产生 deviceId 相同的多条结果,
/// 必须按 deviceId 去重,否则 SwiftUI ForEach(id: deviceId) 出现重复 id → 渲染异常/告警。
///
/// 期望输出:`ALL PASS`,否则 `FAIL: ...` 到 stderr + exit(1)。

@main
struct PeerDiscoveryDedupTests {
    static func main() {
        let ep1 = NWEndpoint.hostPort(host: "127.0.0.1", port: 5000)
        let ep2 = NWEndpoint.hostPort(host: "127.0.0.2", port: 5000)
        let peers = [
            DiscoveredPeer(deviceId: "A", name: "MacA", fingerprint: "fa", endpoint: ep1),
            DiscoveredPeer(deviceId: "B", name: "MacB", fingerprint: "fb", endpoint: ep1),
            DiscoveredPeer(deviceId: "A", name: "MacA", fingerprint: "fa", endpoint: ep2),  // 同一设备另一接口
        ]
        let out = PeerDiscovery.deduped(peers)
        expect(out.count == 2, "同一 deviceId 应只保留一条,实际 \(out.count)")
        expect(out.map(\.deviceId) == ["A", "B"], "应保留首次出现顺序 [A, B],实际 \(out.map(\.deviceId))")
        print("ALL PASS")
    }

    static func expect(_ c: Bool, _ m: String) {
        if !c {
            FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8))
            exit(1)
        }
    }
}
