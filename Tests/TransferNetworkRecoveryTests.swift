import Foundation
import Network

@main
struct TransferNetworkRecoveryTests {
    static func main() {
        expect(TransferNetworkTransition.next(previous: nil, current: true) == .initial,
               "首次可用建立基线，服务层同时把它作为一次有效恢复事件")
        expect(TransferNetworkTransition.next(previous: nil, current: false) == .becameUnavailable,
               "首次不可用要阻止拨号")
        expect(TransferNetworkTransition.next(previous: false, current: true) == .restored,
               "不可用→可用必须触发恢复")
        expect(TransferNetworkTransition.next(previous: true, current: true) == .unchanged,
               "重复可用不能重开周期")

        let a = DiscoveredPeer(deviceId: "A", name: "Mac", fingerprint: "fp",
                               endpoint: .hostPort(host: "127.0.0.1", port: 5000))
        let b = DiscoveredPeer(deviceId: "A", name: "Mac", fingerprint: "fp",
                               endpoint: .hostPort(host: "127.0.0.1", port: 5001))
        expect(a.reconnectEndpointKey != b.reconnectEndpointKey,
               "监听端口变化必须形成新的恢复事件")

        let service = NWEndpoint.service(name: "peer-A", type: "_easysign-transfer._tcp",
                                         domain: "local.", interface: nil)
        let s1 = DiscoveredPeer(deviceId: "A", name: "Mac", fingerprint: "fp",
                                endpoint: service, recoveryToken: "browser-7/change-1")
        let s2 = DiscoveredPeer(deviceId: "A", name: "Mac", fingerprint: "fp",
                                endpoint: service, recoveryToken: "browser-7/change-2")
        expect(s1.reconnectEndpointKey != s2.reconnectEndpointKey,
               "同一 Bonjour service 身份发生 changed 时也必须形成新恢复事件")
        print("ALL PASS")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1)
        }
    }
}
