import Foundation

@main
struct TransferNetworkPathPresentationTests {
    static func main() {
        expect(
            TransferNetworkPathPresentation.summary(
                isSatisfied: false,
                usesWiFi: false,
                usesWiredEthernet: false
            ) == .unavailable,
            "an unsatisfied path must never be described as usable"
        )
        expect(
            TransferNetworkPathPresentation.summary(
                isSatisfied: false,
                usesWiFi: true,
                usesWiredEthernet: true
            ) == .unavailable,
            "an unsatisfied path takes precedence over reported interface types"
        )
        expect(
            TransferNetworkPathPresentation.summary(
                isSatisfied: true,
                usesWiFi: true,
                usesWiredEthernet: false
            ) == .wifi,
            "a satisfied Wi-Fi path is presented as Wi-Fi"
        )
        expect(
            TransferNetworkPathPresentation.summary(
                isSatisfied: true,
                usesWiFi: false,
                usesWiredEthernet: true
            ) == .wired,
            "a satisfied wired path is presented as wired"
        )
        expect(
            TransferNetworkPathPresentation.summary(
                isSatisfied: true,
                usesWiFi: false,
                usesWiredEthernet: false
            ) == .available,
            "other satisfied paths remain factual but generic"
        )
        expect(TransferNetworkPathSummary.checking.title == "正在检测", "checking copy stays explicit")
        expect(TransferNetworkPathSummary.unavailable.title == "不可用", "unavailable copy stays explicit")
        expect(TransferNetworkPathSummary.wifi.title == "Wi-Fi", "Wi-Fi copy stays factual")
        expect(TransferNetworkPathSummary.wired.title == "有线网络", "wired copy stays factual")
        expect(TransferNetworkPathSummary.available.title == "可用", "generic available copy does not claim network quality")
        expect(
            TransferNetworkPathUpdateGate.accepts(
                updateGeneration: 3,
                currentGeneration: 3,
                isMonitoring: true
            ),
            "the current monitor may publish its path"
        )
        expect(
            !TransferNetworkPathUpdateGate.accepts(
                updateGeneration: 2,
                currentGeneration: 3,
                isMonitoring: true
            ),
            "a previous monitor cannot overwrite a restarted monitor"
        )
        expect(
            !TransferNetworkPathUpdateGate.accepts(
                updateGeneration: 3,
                currentGeneration: 3,
                isMonitoring: false
            ),
            "a stopped monitor cannot publish a queued callback"
        )
        print("ALL PASS")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }
}
