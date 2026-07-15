// swiftc -swift-version 5 -strict-concurrency=complete -warnings-as-errors -module-cache-path /tmp/easysign-swift-module-cache EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/TransferNetworkMonitor.swift Tests/TransferNetworkRecoveryTests.swift -o /tmp/transfer-network-recovery
// /tmp/transfer-network-recovery

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

        testMonitorLifecycle()
        testStopFromCallbackQueue()
        testDeinitCancelsSynchronously()
        print("ALL PASS")
    }

    static func testMonitorLifecycle() {
        let factory = FakePathMonitorFactory()
        let events = EventRecorder()
        let monitor = TransferNetworkMonitor(
            onPathChanged: { satisfied, transition in
                events.append(satisfied: satisfied, transition: transition)
            },
            monitorFactory: { factory.make() }
        )

        monitor.start()
        monitor.start()
        expect(factory.createdCount == 1, "双 start 只能创建一个 path monitor")

        let first = factory.monitor(at: 0)
        first.emit(true)
        expect(events.last?.transition == .initial, "首个 satisfied 应发布 initial")

        monitor.stop()
        let countAfterStop = events.count
        first.emit(false)
        expect(events.count == countAfterStop, "stop 返回后旧 monitor emit 必须被拒绝")

        monitor.start()
        expect(factory.createdCount == 2, "stop 后 start 必须创建新 monitor")
        let second = factory.monitor(at: 1)
        first.emit(true)
        expect(events.count == countAfterStop, "restart 后旧 monitor callback 必须继续被拒绝")
        second.emit(false)
        expect(events.last?.transition == .becameUnavailable,
               "restart 后 previous 基线必须清空并由新 monitor 建立")
        monitor.stop()
    }

    static func testStopFromCallbackQueue() {
        let factory = FakePathMonitorFactory()
        let reference = MonitorReference()
        let callbackReturned = DispatchSemaphore(value: 0)
        let monitor = TransferNetworkMonitor(
            onPathChanged: { _, _ in
                reference.value?.stop()
                callbackReturned.signal()
            },
            monitorFactory: { factory.make() }
        )
        reference.value = monitor
        monitor.start()

        let fake = factory.monitor(at: 0)
        DispatchQueue.global().async {
            fake.emit(true)
        }
        expect(callbackReturned.wait(timeout: .now() + 2) == .success,
               "从 monitor callback queue 调 stop 不得死锁")
        expect(fake.cancelCount == 1, "callback 内 stop 必须同步 cancel 当前 monitor")
        reference.value = nil
    }

    static func testDeinitCancelsSynchronously() {
        let factory = FakePathMonitorFactory()
        var monitor: TransferNetworkMonitor? = TransferNetworkMonitor(
            onPathChanged: { _, _ in },
            monitorFactory: { factory.make() }
        )
        monitor?.start()
        let fake = factory.monitor(at: 0)
        monitor = nil
        expect(fake.cancelCount == 1, "deinit 返回前必须在线性化队列上清理 monitor")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1)
        }
    }

    final class FakePathMonitorFactory: @unchecked Sendable {
        private let lock = NSLock()
        private var monitors: [FakePathMonitor] = []

        var createdCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return monitors.count
        }

        func make() -> any TransferPathMonitoring {
            let monitor = FakePathMonitor()
            lock.lock()
            monitors.append(monitor)
            lock.unlock()
            return monitor
        }

        func monitor(at index: Int) -> FakePathMonitor {
            lock.lock()
            defer { lock.unlock() }
            return monitors[index]
        }
    }

    final class FakePathMonitor: TransferPathMonitoring, @unchecked Sendable {
        private let lock = NSLock()
        private var callbackQueue: DispatchQueue?
        private var updateHandler: (@Sendable (Bool) -> Void)?
        private var cancelCountStorage = 0

        var cancelCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return cancelCountStorage
        }

        func start(queue: DispatchQueue,
                   updateHandler: @escaping @Sendable (Bool) -> Void) {
            lock.lock()
            callbackQueue = queue
            self.updateHandler = updateHandler
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelCountStorage += 1
            lock.unlock()
        }

        func emit(_ satisfied: Bool) {
            lock.lock()
            let queue = callbackQueue
            let handler = updateHandler
            lock.unlock()
            guard let queue, let handler else { return }
            queue.sync {
                handler(satisfied)
            }
        }
    }

    final class EventRecorder: @unchecked Sendable {
        struct Event: Sendable {
            let satisfied: Bool
            let transition: TransferNetworkTransition
        }

        private let lock = NSLock()
        private var events: [Event] = []

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return events.count
        }

        var last: Event? {
            lock.lock()
            defer { lock.unlock() }
            return events.last
        }

        func append(satisfied: Bool, transition: TransferNetworkTransition) {
            lock.lock()
            events.append(Event(satisfied: satisfied, transition: transition))
            lock.unlock()
        }
    }

    final class MonitorReference: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: TransferNetworkMonitor?

        var value: TransferNetworkMonitor? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
            set {
                lock.lock()
                storage = newValue
                lock.unlock()
            }
        }
    }
}
