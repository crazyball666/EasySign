import Foundation
import Network

protocol TransferPathMonitoring: AnyObject, Sendable {
    func start(queue: DispatchQueue,
               updateHandler: @escaping @Sendable (Bool) -> Void)
    func cancel()
}

/// NWPathMonitor 的薄适配层；其 handler/start/cancel 仅由 TransferNetworkMonitor 的队列调用。
private final class NWTransferPathMonitor: TransferPathMonitoring, @unchecked Sendable {
    private let monitor = NWPathMonitor()

    func start(queue: DispatchQueue,
               updateHandler: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in
            updateHandler(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }
}

/// App 生命周期级网络可用性监听，不依赖 SwiftUI view 生命周期。
/// `@unchecked Sendable` 的依据：所有 State 读写由私有串行 queue 线性化，回调/factory 均为 Sendable。
final class TransferNetworkMonitor: @unchecked Sendable {
    /// State 跨 @Sendable queue closure 传递，但字段只允许在 owner queue 访问。
    private final class State: @unchecked Sendable {
        var monitor: (any TransferPathMonitoring)?
        var generation: UInt = 0
        var previousSatisfied: Bool?
    }

    private typealias MonitorFactory = @Sendable () -> any TransferPathMonitoring

    private let queue = DispatchQueue(label: "transfer.network-monitor")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let state = State()
    private let monitorFactory: MonitorFactory
    private let onPathChanged: @Sendable (Bool, TransferNetworkTransition) -> Void

    init(onPathChanged: @escaping @Sendable (Bool, TransferNetworkTransition) -> Void,
         monitorFactory: @escaping @Sendable () -> any TransferPathMonitoring = {
             NWTransferPathMonitor()
         }) {
        self.onPathChanged = onPathChanged
        self.monitorFactory = monitorFactory
        queue.setSpecific(key: queueKey, value: 1)
    }

    func start() {
        let state = state
        let queue = queue
        let monitorFactory = monitorFactory
        let onPathChanged = onPathChanged
        let operation: @Sendable () -> Void = {
            guard state.monitor == nil else { return }

            state.generation &+= 1
            let generation = state.generation
            let monitor = monitorFactory()
            state.monitor = monitor
            monitor.start(queue: queue) { [weak monitor] isSatisfied in
                guard let monitor,
                      state.generation == generation,
                      state.monitor === monitor else { return }
                let transition = TransferNetworkTransition.next(
                    previous: state.previousSatisfied,
                    current: isSatisfied
                )
                state.previousSatisfied = isSatisfied
                onPathChanged(isSatisfied, transition)
            }
        }
        performOnQueue(operation)
    }

    /// 返回前同步失效并取消当前 monitor；排队中的旧 callback 会被 generation/实例门禁拒绝。
    func stop() {
        let state = state
        let operation: @Sendable () -> Void = {
            Self.clear(state)
        }
        performOnQueue(operation)
    }

    deinit {
        let state = state
        let operation: @Sendable () -> Void = {
            Self.clear(state)
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            operation()
        } else {
            queue.sync(execute: operation)
        }
    }

    private func performOnQueue(_ operation: @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            operation()
        } else {
            queue.sync(execute: operation)
        }
    }

    private static func clear(_ state: State) {
        state.generation &+= 1
        let monitor = state.monitor
        state.monitor = nil
        state.previousSatisfied = nil
        monitor?.cancel()
    }
}
