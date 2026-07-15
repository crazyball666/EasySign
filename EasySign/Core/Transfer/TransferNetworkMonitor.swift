import Foundation
import Network

/// App 生命周期级网络可用性监听，不依赖 SwiftUI view 生命周期。
final class TransferNetworkMonitor {
    private final class State {
        var monitor: NWPathMonitor?
        var previousSatisfied: Bool?
    }

    private let queue = DispatchQueue(label: "transfer.network-monitor")
    private let state = State()
    private let onPathChanged: (Bool, TransferNetworkTransition) -> Void

    init(onPathChanged: @escaping (Bool, TransferNetworkTransition) -> Void) {
        self.onPathChanged = onPathChanged
    }

    func start() {
        let state = state
        let queue = queue
        let onPathChanged = onPathChanged
        queue.async {
            guard state.monitor == nil else { return }

            let monitor = NWPathMonitor()
            state.monitor = monitor
            monitor.pathUpdateHandler = { [weak monitor] path in
                guard let monitor, state.monitor === monitor else { return }
                let isSatisfied = path.status == .satisfied
                let transition = TransferNetworkTransition.next(
                    previous: state.previousSatisfied,
                    current: isSatisfied
                )
                state.previousSatisfied = isSatisfied
                onPathChanged(isSatisfied, transition)
            }
            monitor.start(queue: queue)
        }
    }

    func stop() {
        let state = state
        queue.async {
            state.monitor?.cancel()
            state.monitor = nil
            state.previousSatisfied = nil
        }
    }

    deinit {
        let state = state
        queue.async {
            state.monitor?.cancel()
            state.monitor = nil
            state.previousSatisfied = nil
        }
    }
}
