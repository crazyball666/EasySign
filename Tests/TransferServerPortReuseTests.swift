import Darwin
import Foundation
import Network

/// Compile and run the pure policy checks with strict concurrency:
/// swiftc -swift-version 5 -strict-concurrency=complete -warnings-as-errors -D POLICY_ONLY -module-cache-path /tmp/easysign-swift-module-cache EasySign/Core/Transfer/TransferListenerPortPolicy.swift Tests/TransferServerPortReuseTests.swift -o /tmp/transfer-server-port-policy && /tmp/transfer-server-port-policy
///
/// Compile and run the policy plus real Network.framework listener reuse check:
/// swiftc -swift-version 5 -module-cache-path /tmp/easysign-swift-module-cache EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/TransferAutoReconnect.swift EasySign/Core/Transfer/TransferTrustedEndpoint.swift EasySign/Core/Transfer/PeerDiscovery.swift EasySign/Core/Transfer/WireMessage.swift EasySign/Core/Transfer/CertFingerprint.swift EasySign/Core/Transfer/DeviceIdentity.swift EasySign/Core/Transfer/TransferTLS.swift EasySign/Core/Transfer/TransferListenerPortPolicy.swift EasySign/Core/Transfer/TransferServer.swift Tests/TransferServerPortReuseTests.swift -o /tmp/transfer-server-port-reuse && /tmp/transfer-server-port-reuse

#if !POLICY_ONLY
/// Thread-safe terminal listener result. Network.framework callbacks arrive on the server queue
/// while the test executable blocks on its main thread.
private final class ListenerReadyProbe {
    enum Result {
        case ready(UInt16)
        case failed(String)
    }

    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result?

    func record(state: NWListener.State, port: UInt16?) {
        let newResult: Result?
        switch state {
        case .ready:
            newResult = port.map(Result.ready)
        case .failed(let error):
            newResult = .failed(String(describing: error))
        default:
            newResult = nil
        }
        guard let newResult else { return }

        lock.lock()
        let shouldSignal = result == nil
        if shouldSignal { result = newResult }
        lock.unlock()
        if shouldSignal { semaphore.signal() }
    }

    func wait(timeout: TimeInterval) -> Result? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

/// Records the production listener's complete preferred-port failure and random fallback sequence.
private final class OccupiedPortFallbackProbe {
    struct Snapshot {
        let addressInUseFailures: Int
        let otherFailures: [String]
        let readyPort: UInt16?
    }

    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var addressInUseFailures = 0
    private var otherFailures: [String] = []
    private var readyPort: UInt16?
    private var didSignal = false

    func record(state: NWListener.State, port: UInt16?) {
        lock.lock()
        switch state {
        case .failed(let error):
            if case .posix(.EADDRINUSE) = error {
                addressInUseFailures += 1
            } else {
                otherFailures.append(String(describing: error))
            }
        case .ready:
            readyPort = port
        default:
            break
        }

        let shouldSignal = !didSignal
            && (readyPort != nil || !otherFailures.isEmpty || addressInUseFailures > 1)
        if shouldSignal { didSignal = true }
        lock.unlock()
        if shouldSignal { semaphore.signal() }
    }

    func wait(timeout: TimeInterval) -> Snapshot {
        _ = semaphore.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            addressInUseFailures: addressInUseFailures,
            otherFailures: otherFailures,
            readyPort: readyPort
        )
    }
}
#endif

@main
struct TransferServerPortReuseTests {
    static func main() {
        testInitialBindingChoice()
        testReadyPortBecomesPreferred()
        testAddressInUseClearsRequestedPreferredPort()
        testOtherFailureKeepsRequestedPreferredPort()
        testRandomFailureDoesNotClearPreferredPort()
        testFailureClassification()
        testZeroPortIsNeverPreferred()

#if !POLICY_ONLY
        do {
            try testStoppedServerPortCanBeReused()
            try testOccupiedPreferredPortFallsBackToRandom()
        } catch {
            fail("real listener reuse threw: \(error)")
        }
#endif

        print("ALL PASS")
    }

    private static func testInitialBindingChoice() {
        let random = TransferListenerPortPolicy()
        expect(random.preferredPort == nil, "initial policy should have no preferred port")
        expect(random.nextBinding == .random, "missing initial preferred port should bind randomly")

        let preferred = TransferListenerPortPolicy(preferredPort: 45_678)
        expect(preferred.preferredPort == 45_678, "valid initial preferred port should be retained")
        expect(preferred.nextBinding == .preferred(45_678), "valid initial port should be requested")
    }

    private static func testReadyPortBecomesPreferred() {
        var policy = TransferListenerPortPolicy()
        policy.listenerReady(port: 43_210)
        expect(policy.preferredPort == 43_210, "ready listener port should become preferred")
        expect(policy.nextBinding == .preferred(43_210), "next listener should reuse the ready port")
    }

    private static func testAddressInUseClearsRequestedPreferredPort() {
        var policy = TransferListenerPortPolicy(preferredPort: 43_211)
        let next = policy.listenerFailed(requestedPort: 43_211, kind: .addressInUse)
        expect(policy.preferredPort == nil, "EADDRINUSE for the requested preferred port should clear it")
        expect(next == .random, "EADDRINUSE for the preferred port should fall back to random")
    }

    private static func testOtherFailureKeepsRequestedPreferredPort() {
        var policy = TransferListenerPortPolicy(preferredPort: 43_212)
        let next = policy.listenerFailed(requestedPort: 43_212, kind: .other)
        expect(policy.preferredPort == 43_212, "non-address failure should retain the preferred port")
        expect(next == .preferred(43_212), "non-address failure should retry the preferred port")
    }

    private static func testRandomFailureDoesNotClearPreferredPort() {
        var policy = TransferListenerPortPolicy(preferredPort: 43_213)
        let next = policy.listenerFailed(requestedPort: nil, kind: .addressInUse)
        expect(policy.preferredPort == 43_213, "a random attempt failure must not clear an existing preference")
        expect(next == .preferred(43_213), "a random attempt failure should preserve the next preferred binding")
    }

    private static func testFailureClassification() {
        expect(
            TransferListenerPortPolicy.failureKind(for: .posix(.EADDRINUSE)) == .addressInUse,
            "POSIX EADDRINUSE should be classified as addressInUse"
        )
        expect(
            TransferListenerPortPolicy.failureKind(for: .posix(.ECONNRESET)) == .other,
            "other POSIX failures should not be classified as addressInUse"
        )
        expect(
            TransferListenerPortPolicy.failureKind(for: .dns(-65_537)) == .other,
            "non-POSIX Network.framework failures should be classified as other"
        )
    }

    private static func testZeroPortIsNeverPreferred() {
        var policy = TransferListenerPortPolicy(preferredPort: 0)
        expect(policy.preferredPort == nil, "initial port zero should be rejected")
        expect(policy.nextBinding == .random, "initial port zero should bind randomly")

        policy.listenerReady(port: 0)
        expect(policy.preferredPort == nil, "ready port zero should not become preferred")
        expect(policy.nextBinding == .random, "ready port zero should leave the next binding random")
    }

#if !POLICY_ONLY
    private static func testStoppedServerPortCanBeReused() throws {
        let material = try DeviceIdentity.generateSelfSigned(commonName: "EasySign-port-reuse")
        let loaded = try DeviceIdentity.importIdentity(
            certDER: material.certDER,
            keyX963: material.keyX963
        )

        let firstProbe = ListenerReadyProbe()
        let first = TransferServer(identity: { loaded.identity })
        first.onStateChange = { state, port in firstProbe.record(state: state, port: port) }
        try first.start()

        let firstResult = firstProbe.wait(timeout: 10)
        guard case .ready(let originalPort)? = firstResult else {
            first.stop()
            fail("first listener did not become ready within 10s: \(describe(firstResult))")
        }

        first.stop()
        expect(
            waitUntil(timeout: 5) { canBindTCPPort(originalPort) },
            "stopped listener should release port \(originalPort) within 5s"
        )

        let secondProbe = ListenerReadyProbe()
        let second = TransferServer(identity: { loaded.identity }, preferredPort: originalPort)
        second.onStateChange = { state, port in secondProbe.record(state: state, port: port) }
        try second.start()

        let secondResult = secondProbe.wait(timeout: 10)
        second.stop()
        guard case .ready(let reusedPort)? = secondResult else {
            fail("preferred listener did not become ready within 10s: \(describe(secondResult))")
        }
        expect(reusedPort == originalPort, "second server should reuse \(originalPort), got \(reusedPort)")
    }

    private static func testOccupiedPreferredPortFallsBackToRandom() throws {
        let material = try DeviceIdentity.generateSelfSigned(commonName: "EasySign-port-fallback")
        let loaded = try DeviceIdentity.importIdentity(
            certDER: material.certDER,
            keyX963: material.keyX963
        )

        let holderProbe = ListenerReadyProbe()
        let holder = TransferServer(identity: { loaded.identity })
        holder.onStateChange = { state, port in holderProbe.record(state: state, port: port) }
        try holder.start()
        defer { holder.stop() }

        let holderResult = holderProbe.wait(timeout: 10)
        guard case .ready(let occupiedPort)? = holderResult else {
            holder.stop()
            fail("holder listener did not become ready within 10s: \(describe(holderResult))")
        }

        let fallbackProbe = OccupiedPortFallbackProbe()
        let fallback = TransferServer(identity: { loaded.identity }, preferredPort: occupiedPort)
        fallback.onStateChange = { state, port in fallbackProbe.record(state: state, port: port) }
        try fallback.start()
        defer { fallback.stop() }

        let snapshot = fallbackProbe.wait(timeout: 10)
        fallback.stop()
        holder.stop()
        let holderPortReleased = waitUntil(timeout: 5) { canBindTCPPort(occupiedPort) }
        let fallbackPortReleased = snapshot.readyPort.map { port in
            waitUntil(timeout: 5) { canBindTCPPort(port) }
        } ?? true

        expect(
            snapshot.otherFailures.isEmpty,
            "occupied preferred port should fail with POSIX EADDRINUSE, got: \(snapshot.otherFailures)"
        )
        expect(
            snapshot.addressInUseFailures == 1,
            "occupied preferred port should produce exactly one EADDRINUSE, got \(snapshot.addressInUseFailures)"
        )
        guard let fallbackPort = snapshot.readyPort else {
            fail("same server did not self-heal onto a random port within 10s")
        }
        expect(fallbackPort != 0, "fallback listener should use a nonzero random port")
        expect(
            fallbackPort != occupiedPort,
            "fallback listener should leave occupied preferred port \(occupiedPort)"
        )
        expect(holderPortReleased, "holder listener should release its port after stop")
        expect(fallbackPortReleased, "fallback listener should release its port after stop")
    }

    private static func canBindTCPPort(_ port: UInt16) -> Bool {
        canBindIPv4TCPPort(port) && canBindIPv6TCPPort(port)
    }

    private static func canBindIPv4TCPPort(_ port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                ) == 0
            }
        }
    }

    private static func canBindIPv6TCPPort(_ port: UInt16) -> Bool {
        let descriptor = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_any

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in6>.size)
                ) == 0
            }
        }
    }

    private static func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    private static func describe(_ result: ListenerReadyProbe.Result?) -> String {
        switch result {
        case .ready(let port): "ready(\(port))"
        case .failed(let message): "failed(\(message))"
        case nil: "timeout"
        }
    }
#endif

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}
