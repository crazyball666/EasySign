import Combine
import Foundation
import Network

/// 仅供互传界面展示的本机网络路径摘要。
///
/// 它不会读取、改变或持久化 `TransferService` 的任何状态；监听器仅用于让界面避免把
/// "正在检测" 或不可用的网络误写成 Wi-Fi / 有线网络。
enum TransferNetworkPathSummary: Equatable {
    case checking
    case unavailable
    case wifi
    case wired
    case available

    var title: String {
        switch self {
        case .checking: "正在检测"
        case .unavailable: "不可用"
        case .wifi: "Wi-Fi"
        case .wired: "有线网络"
        case .available: "可用"
        }
    }

    var symbol: String {
        switch self {
        case .checking: "network"
        case .unavailable: "wifi.slash"
        case .wifi: "wifi"
        case .wired: "cable.connector"
        case .available: "network"
        }
    }
}

enum TransferNetworkPathPresentation {
    static func summary(
        isSatisfied: Bool,
        usesWiFi: Bool,
        usesWiredEthernet: Bool
    ) -> TransferNetworkPathSummary {
        guard isSatisfied else { return .unavailable }
        if usesWiFi { return .wifi }
        if usesWiredEthernet { return .wired }
        return .available
    }
}

enum TransferNetworkPathUpdateGate {
    static func accepts(
        updateGeneration: UInt,
        currentGeneration: UInt,
        isMonitoring: Bool
    ) -> Bool {
        isMonitoring && updateGeneration == currentGeneration
    }
}

@MainActor
final class TransferNetworkPathObserver: ObservableObject {
    @Published private(set) var summary: TransferNetworkPathSummary = .checking

    private var monitor: NWPathMonitor?
    private var generation: UInt = 0
    private let queue = DispatchQueue(label: "EasySign.TransferNetworkPathObserver")

    func start() {
        guard monitor == nil else { return }

        generation &+= 1
        let updateGeneration = generation
        summary = .checking
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let summary = TransferNetworkPathPresentation.summary(
                isSatisfied: path.status == .satisfied,
                usesWiFi: path.usesInterfaceType(.wifi),
                usesWiredEthernet: path.usesInterfaceType(.wiredEthernet)
            )
            Task { @MainActor [weak self] in
                guard let self,
                      TransferNetworkPathUpdateGate.accepts(
                        updateGeneration: updateGeneration,
                        currentGeneration: self.generation,
                        isMonitoring: self.monitor != nil
                      )
                else { return }
                self.summary = summary
            }
        }
        self.monitor = monitor
        monitor.start(queue: queue)
    }

    func stop() {
        generation &+= 1
        monitor?.cancel()
        monitor = nil
        summary = .checking
    }

    deinit {
        monitor?.cancel()
    }
}
