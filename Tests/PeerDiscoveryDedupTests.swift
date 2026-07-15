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
        expect(PeerDiscoveryGenerationGate.accepts(updateGeneration: 3,
                                                   currentGeneration: 3,
                                                   isBrowsing: true),
               "当前 browser 可以发布")
        expect(!PeerDiscoveryGenerationGate.accepts(updateGeneration: 2,
                                                    currentGeneration: 3,
                                                    isBrowsing: true),
               "旧 browser 回调必须丢弃")
        expect(!PeerDiscoveryGenerationGate.accepts(updateGeneration: 3,
                                                    currentGeneration: 3,
                                                    isBrowsing: false),
               "stop 后的回调必须丢弃")
        expect(PeerDiscoveryRecoveryToken.make(browserGeneration: 7, changeRevision: 1)
               != PeerDiscoveryRecoveryToken.make(browserGeneration: 7, changeRevision: 2),
               "Bonjour changed 必须推进恢复 token")

        var tokens = PeerDiscoveryRecoveryTokenStore()
        let firstA = tokens.recordChange(for: "A", browserGeneration: 7)
        _ = tokens.recordChange(for: "B", browserGeneration: 7)
        expect(tokens.token(for: "A") == firstA,
               "无关 peer change 不得推进目标设备 token")
        let changedA = tokens.recordChange(for: "A", browserGeneration: 7)
        expect(changedA != firstA, "同一设备任一接口 changed 都必须推进设备 token")
        tokens.removeTokensForInactiveDevices(activeDeviceIds: ["A"])
        expect(tokens.token(for: "A") == changedA,
               "同设备仍有其他接口时 removed 不得清除设备 token")
        tokens.removeTokensForInactiveDevices(activeDeviceIds: [])
        expect(tokens.token(for: "A") == nil,
               "设备最后一个接口 removed 后必须清除 token")
        print("ALL PASS")
    }

    static func expect(_ c: Bool, _ m: String) {
        if !c {
            FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8))
            exit(1)
        }
    }
}
