import Foundation
import Network
import Security

/// Compile and run:
/// swiftc -swift-version 5 -module-cache-path /tmp/easysign-swift-module-cache \
///   EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/TransferAutoReconnect.swift \
///   EasySign/Core/Transfer/TransferTrustedEndpoint.swift EasySign/Core/Transfer/PeerDiscovery.swift \
///   EasySign/Core/Transfer/WireMessage.swift EasySign/Core/Transfer/CertFingerprint.swift \
///   EasySign/Core/Transfer/DeviceIdentity.swift EasySign/Core/Transfer/PairingCrypto.swift \
///   EasySign/Core/Transfer/PairingManager.swift EasySign/Core/Transfer/TransferTLS.swift \
///   EasySign/Core/Transfer/TransferListenerPortPolicy.swift EasySign/Core/Transfer/TransferServer.swift \
///   EasySign/Core/Transfer/TransferClient.swift EasySign/Core/Transfer/TransferPaths.swift \
///   EasySign/Core/Transfer/FileTransferManager.swift Tests/TransferLoopbackTests.swift \
///   -o /tmp/transfer-loopback && /tmp/transfer-loopback

/// Standalone loopback integration test for the secure-channel + pairing stack.
/// Exercises the REAL Network.framework + Security stack over 127.0.0.1:
///   1. two self-signed identities (distinct fingerprints)
///   2. mutual-TLS handshake + peer fingerprint/remote-host capture
///   3. symmetric PairingManager handshake -> mutual success
///   4. bidirectional reconnectHint delivery over the bound channel
///   5. trusted host/port reconnect with the paired fingerprint and no pairing code
///   6. clipboard and file delivery still work after bound-handler replacement
///   7. TLS pinning rejects a wrong-fingerprint client (negative test)
///
/// Prints `ALL PASS` only if every assertion holds; otherwise `FAIL: ...` to stderr + exit(1).

/// Thread-safe latest-value box (callbacks fire on Network.framework queues; main blocks on waits).
final class Latest<T> {
    private let lock = NSLock()
    private var v: T
    init(_ initial: T) { v = initial }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ n: T) { lock.lock(); v = n; lock.unlock() }
}

/// Thread-safe strong owner for every server-side inbound connection created by the test.
final class ConnectionCollector {
    private let condition = NSCondition()
    private var connections: [TransferConnection] = []

    var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return connections.count
    }

    func append(_ connection: TransferConnection) {
        condition.lock()
        connections.append(connection)
        condition.broadcast()
        condition.unlock()
    }

    func waitForCount(_ expectedCount: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while connections.count < expectedCount {
            guard condition.wait(until: deadline) else { return connections.count >= expectedCount }
        }
        return true
    }

    func connection(at index: Int) -> TransferConnection? {
        condition.lock()
        defer { condition.unlock() }
        return connections.indices.contains(index) ? connections[index] : nil
    }

    func cancelAll() {
        condition.lock()
        let retained = connections
        condition.unlock()
        retained.forEach { $0.cancel() }
    }
}

/// Thread-safe state history for a connection whose TLS pin is expected to reject.
/// `.waiting` is deliberately non-terminal: Network.framework may recover from it.
final class ConnectionStateTracker {
    struct Snapshot {
        let everReady: Bool
        let terminalState: String?
        let lastState: String
        let lastStateIsWaiting: Bool
    }

    private let condition = NSCondition()
    private var everReady = false
    private var terminalState: String?
    private var lastState = "unobserved"
    private var lastStateIsWaiting = false

    var snapshot: Snapshot {
        condition.lock()
        defer { condition.unlock() }
        return snapshotLocked()
    }

    func record(_ state: NWConnection.State) {
        condition.lock()
        lastState = Self.describe(state)
        lastStateIsWaiting = false
        switch state {
        case .ready:
            everReady = true
        case .waiting:
            lastStateIsWaiting = true
        case .failed, .cancelled:
            if terminalState == nil { terminalState = lastState }
        default:
            break
        }
        condition.broadcast()
        condition.unlock()
    }

    /// Waits until a state that decides the negative test (`ready`, `failed`, or `cancelled`),
    /// or returns the latest non-terminal state when the bounded observation window expires.
    func waitForReadyOrTerminal(timeout: TimeInterval) -> Snapshot {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !everReady && terminalState == nil {
            guard condition.wait(until: deadline) else { break }
        }
        return snapshotLocked()
    }

    private func snapshotLocked() -> Snapshot {
        Snapshot(
            everReady: everReady,
            terminalState: terminalState,
            lastState: lastState,
            lastStateIsWaiting: lastStateIsWaiting
        )
    }

    private static func describe(_ state: NWConnection.State) -> String {
        switch state {
        case .setup: return "setup"
        case .waiting(let error): return "waiting(\(error))"
        case .preparing: return "preparing"
        case .ready: return "ready"
        case .failed(let error): return "failed(\(error))"
        case .cancelled: return "cancelled"
        @unknown default: return "unknown"
        }
    }
}

@main
struct TransferLoopbackTests {
    static func main() {
        verifyWrongPinOracleRejectsWaitingMutation()
        do { try run() } catch { fail("threw: \(error)") }
    }

    static func verifyWrongPinOracleRejectsWaitingMutation() {
        let tracker = ConnectionStateTracker()
        tracker.record(.waiting(.posix(.ENETDOWN)))
        let waiting = tracker.waitForReadyOrTerminal(timeout: 0.01)
        expect(!waiting.everReady && waiting.terminalState == nil && waiting.lastStateIsWaiting,
               "controlled mutation: waiting must remain non-terminal")
        tracker.record(.ready)
        expect(tracker.snapshot.everReady,
               "controlled mutation: a later ready must remain visible to the wrong-pin oracle")
    }

    static func run() throws {
        // ---- Stage 1: two identities -------------------------------------------------
        let matA = try DeviceIdentity.generateSelfSigned(commonName: "EasySign-A")
        let matB = try DeviceIdentity.generateSelfSigned(commonName: "EasySign-B")
        let idA = try DeviceIdentity.importIdentity(certDER: matA.certDER, keyX963: matA.keyX963)
        let idB = try DeviceIdentity.importIdentity(certDER: matB.certDER, keyX963: matB.keyX963)
        expect(idA.fingerprint.count == 64 && idB.fingerprint.count == 64,
               "fingerprints are 64 hex chars")
        expect(idA.fingerprint != idB.fingerprint, "two identities have distinct fingerprints")
        log("stage1 ok: idA=\(idA.fingerprint.prefix(8))… idB=\(idB.fingerprint.prefix(8))…")

        // ---- Bring up server (idB) ---------------------------------------------------
        let server = TransferServer(identity: { idB.identity })
        let inboundConnections = ConnectionCollector()
        server.onConnection = { conn in
            // Retain every inbound through cleanup: TLS failure paths are asynchronous and a weak
            // wrapper could otherwise disappear before the test observes the final outcome.
            inboundConnections.append(conn)
        }
        try server.start()
        expect(waitUntil(timeout: 10) { server.port != nil }, "server bound a port")
        let port = server.port!
        log("server listening on 127.0.0.1:\(port)")

        // ---- Client (idA) connects with .acceptAny ----------------------------------
        let client = TransferClient(identity: { idA.identity })
        let clientConn = try client.connect(host: "127.0.0.1", port: port, pin: .acceptAny)
        expect(inboundConnections.waitForCount(1, timeout: 10), "server accepted the initial connection")
        guard let serverConn = inboundConnections.connection(at: 0) else {
            return fail("initial server connection was not retained")
        }

        // ---- Stage 2: TLS ready + per-connection fingerprint capture -----------------
        let bothReady = waitUntil(timeout: 10) {
            clientConn.peerFingerprint != nil && serverConn.peerFingerprint != nil
        }
        expect(bothReady, "both connections reached .ready with a captured peer fingerprint")
        expect(clientConn.peerFingerprint == idB.fingerprint,
               "client captured server(idB) fingerprint, got \(clientConn.peerFingerprint ?? "nil")")
        expect(serverConn.peerFingerprint == idA.fingerprint,
               "server captured client(idA) fingerprint, got \(serverConn.peerFingerprint ?? "nil")")
        guard let clientRemoteHost = clientConn.remoteHost,
              let serverRemoteHost = serverConn.remoteHost else {
            return fail("both ready connections must expose a direct remote host")
        }
        expect(isLoopbackHost(clientRemoteHost),
               "client remote host represents loopback, got \(clientRemoteHost)")
        expect(isLoopbackHost(serverRemoteHost),
               "server remote host represents loopback, got \(serverRemoteHost)")
        log("stage2 ok: mutual TLS + fingerprints + remote hosts \(clientRemoteHost)/\(serverRemoteHost)")

        // ---- Stage 3: pairing handshake (symmetric, both sides) ----------------------
        let code = PairingCrypto.makeCode()
        let pmA = PairingManager(code: code, selfFingerprint: idA.fingerprint,
                                 selfDeviceId: "device-A", selfName: "DeviceA",
                                 peerFingerprint: clientConn.peerFingerprint!)
        let pmB = PairingManager(code: code, selfFingerprint: idB.fingerprint,
                                 selfDeviceId: "device-B", selfName: "DeviceB",
                                 peerFingerprint: serverConn.peerFingerprint!)

        let outA = Latest<PairingManager.Outcome?>(nil)
        let outB = Latest<PairingManager.Outcome?>(nil)
        let semA = DispatchSemaphore(value: 0)
        let semB = DispatchSemaphore(value: 0)

        // Wire send/outcome BEFORE handlers, and handlers BEFORE begin() so no message races ahead.
        pmA.send = { clientConn.send($0) }
        pmB.send = { serverConn.send($0) }
        pmA.onOutcome = { outA.set($0); semA.signal() }
        pmB.onOutcome = { outB.set($0); semB.signal() }
        clientConn.onMessage = { pmA.handle($0) }
        serverConn.onMessage = { pmB.handle($0) }

        pmA.begin()
        pmB.begin()

        expect(semA.wait(timeout: .now() + 10) == .success, "pmA produced an outcome")
        expect(semB.wait(timeout: .now() + 10) == .success, "pmB produced an outcome")

        guard case let .success(peerSeenByA)? = outA.value else {
            return fail("pmA outcome was not .success: \(String(describing: outA.value))")
        }
        guard case let .success(peerSeenByB)? = outB.value else {
            return fail("pmB outcome was not .success: \(String(describing: outB.value))")
        }
        expect(peerSeenByA.fingerprint == idB.fingerprint,
               "A's paired peer fingerprint == idB (\(peerSeenByA.fingerprint.prefix(8))…)")
        expect(peerSeenByB.fingerprint == idA.fingerprint,
               "B's paired peer fingerprint == idA (\(peerSeenByB.fingerprint.prefix(8))…)")
        expect(peerSeenByA.deviceId == "device-B", "A learned B's deviceId via hello")
        expect(peerSeenByB.deviceId == "device-A", "B learned A's deviceId via hello")
        log("stage3 ok: mutual pairing success (code=\(code))")

        // ---- Stage 4: bound reconnect hints travel intact in both directions ---------
        let hintSeenByA = Latest<UInt16?>(nil)
        let hintSeenByB = Latest<UInt16?>(nil)
        let hintSemA = DispatchSemaphore(value: 0)
        let hintSemB = DispatchSemaphore(value: 0)
        clientConn.onMessage = { msg in
            if case let .reconnectHint(hintPort) = msg {
                hintSeenByA.set(hintPort); hintSemA.signal()
            }
        }
        serverConn.onMessage = { msg in
            if case let .reconnectHint(hintPort) = msg {
                hintSeenByB.set(hintPort); hintSemB.signal()
            }
        }

        let listenerPortA: UInt16 = 45_678
        serverConn.send(.reconnectHint(port: port))
        clientConn.send(.reconnectHint(port: listenerPortA))
        expect(hintSemA.wait(timeout: .now() + 10) == .success,
               "A received B's reconnect hint")
        expect(hintSemB.wait(timeout: .now() + 10) == .success,
               "B received A's reconnect hint")
        expect(hintSeenByA.value == port,
               "B's listener port arrived intact (\(hintSeenByA.value.map(String.init) ?? "nil") vs \(port))")
        expect(hintSeenByB.value == listenerPortA,
               "A's listener port arrived intact (\(hintSeenByB.value.map(String.init) ?? "nil") vs \(listenerPortA))")
        log("stage4 ok: reconnect hints delivered intact in both directions")

        // ---- Stage 5: pinned trusted direct reconnect needs no PairingManager --------
        guard let learnedServerPort = hintSeenByA.value else {
            return fail("A did not retain B's reconnect hint port")
        }
        let inboundBeforeTrustedDial = inboundConnections.count
        let trustedClient = TransferClient(identity: { idA.identity })
        let trustedClientConn = try trustedClient.connect(
            host: clientRemoteHost,
            port: learnedServerPort,
            pin: .requirePinned(fingerprint: idB.fingerprint)
        )
        expect(inboundConnections.waitForCount(inboundBeforeTrustedDial + 1, timeout: 10),
               "server accepted the trusted direct connection")
        guard let trustedServerConn = inboundConnections.connection(at: inboundBeforeTrustedDial) else {
            return fail("trusted direct server connection was not retained")
        }
        expect(waitUntil(timeout: 10) {
            trustedClientConn.peerFingerprint == idB.fingerprint
                && trustedServerConn.peerFingerprint == idA.fingerprint
        }, "trusted direct connection became ready on both ends with paired fingerprints")
        expect(isReady(trustedClientConn.nw.state),
               "trusted direct client reached ready, state=\(describe(trustedClientConn.nw.state))")
        expect(isReady(trustedServerConn.nw.state),
               "trusted direct server inbound reached ready, state=\(describe(trustedServerConn.nw.state))")
        expect(trustedClientConn.peerFingerprint == idB.fingerprint,
               "trusted direct client pinned idB without a pairing code")
        expect(trustedServerConn.peerFingerprint == idA.fingerprint,
               "trusted direct server captured idA")
        log("stage5 ok: observed host + hint port reconnected with the paired TLS pin")
        trustedClientConn.cancel()
        trustedServerConn.cancel()

        // ---- Stage 6: clipboard message delivery after bound handler replacement -----
        let clip = Latest<String?>(nil)
        let clipSem = DispatchSemaphore(value: 0)
        serverConn.onMessage = { msg in
            if case let .clipboardText(text, _) = msg {
                clip.set(text); clipSem.signal()
            }
        }
        clientConn.send(.clipboardText(text: "hello 世界", contentHash: "h"))
        expect(clipSem.wait(timeout: .now() + 10) == .success, "server received a clipboard message")
        expect(clip.value == "hello 世界", "clipboard text round-trips exactly, got \(clip.value ?? "nil")")
        log("stage6 ok: clipboard message delivered intact")

        // ---- Stage 7: pinning rejects a stranger (negative) -------------------------
        let wrongFp = String(repeating: "0", count: 64)
        expect(wrongFp != idB.fingerprint, "wrong pin differs from the real server fingerprint")
        let inboundBeforeWrongPin = inboundConnections.count
        let client2 = TransferClient(identity: { idA.identity })
        let badStateTracker = ConnectionStateTracker()
        let badConn = try client2.connect(host: "127.0.0.1", port: port,
                                          pin: .requirePinned(fingerprint: wrongFp))
        // Install immediately after connect returns. The setter replays TransferConnection's
        // latest state; peerFingerprint below independently catches a ready missed before replay.
        badConn.onStateChange = { badStateTracker.record($0) }
        expect(inboundConnections.waitForCount(inboundBeforeWrongPin + 1, timeout: 10),
               "server retained the wrong-pin inbound until cleanup")

        var badObservation = badStateTracker.waitForReadyOrTerminal(timeout: 10)
        expect(!badObservation.everReady,
               "pinned-wrong connection must never reach ready (last=\(badObservation.lastState))")
        if badObservation.terminalState == nil {
            expect(badObservation.lastStateIsWaiting,
                   "wrong-pin connection was non-terminal but not waiting after 10s (last=\(badObservation.lastState))")
            // A recoverable `.waiting` is not proof of rejection. Keep the tracker installed for
            // a complete grace window so a later `.ready` cannot turn into a false negative.
            badObservation = badStateTracker.waitForReadyOrTerminal(timeout: 2)
            expect(!badObservation.everReady,
                   "pinned-wrong connection reached ready during waiting grace")
        }
        expect(badObservation.terminalState != nil || badObservation.lastStateIsWaiting,
               "wrong-pin connection neither terminated nor stayed waiting (last=\(badObservation.lastState))")
        expect(badConn.peerFingerprint == nil,
               "wrong-pin connection captured a peer fingerprint, so it reached ready before observation")

        let rejectionState = badObservation.terminalState ?? "waiting through the full observation window"
        badConn.cancel()
        let afterCancel = badStateTracker.waitForReadyOrTerminal(timeout: 2)
        expect(!afterCancel.everReady,
               "pinned-wrong connection reached ready before cancellation completed")
        expect(afterCancel.terminalState != nil,
               "pinned-wrong connection did not become terminal after explicit cleanup")
        expect(badConn.peerFingerprint == nil,
               "pinned-wrong connection captured a peer fingerprint during cleanup")
        log("stage7 ok: TLS pinning rejected the wrong-fingerprint client (observed \(rejectionState))")

        // ---- Stage 8: chunked binary file round-trip over the paired channel ----------
        // connA = clientConn (sender), connB = serverConn (receiver). Deterministic bytes
        // (index-based, NOT random) so the comparison is reproducible without Date/rand.
        let payloadSize = 200_000
        var srcBytes = Data(count: payloadSize)
        for i in 0..<payloadSize { srcBytes[i] = UInt8(i % 251) }
        let srcURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3a-src-\(getpid()).bin")
        try srcBytes.write(to: srcURL)

        let recvMgr = FileTransferManager()
        let sendMgr = FileTransferManager()
        let recvURLBox = Latest<URL?>(nil)
        let recvSem = DispatchSemaphore(value: 0)
        recvMgr.onReceived = { _, _, url, _ in recvURLBox.set(url); recvSem.signal() }

        // Receiver wiring: binary chunks -> recvMgr; route file control frames from onMessage.
        serverConn.onBinary = { recvMgr.handleBinary($0) }
        serverConn.onMessage = { msg in
            switch msg {
            case let .fileOffer(id, name, size):
                recvMgr.handleOffer(id: id, name: name, size: size, isImage: false)
            case let .fileComplete(id):
                recvMgr.handleComplete(id: id)
            default:
                break
            }
        }

        // Sender wiring: offer/complete as text WS frames, chunks as binary WS frames.
        let fileId = UUID().uuidString
        sendMgr.send(id: fileId, name: "p3a-payload.bin", fileURL: srcURL, isImage: false,
            offer: { id, name, size in clientConn.send(.fileOffer(id: id, name: name, size: size)) },
            sendBinary: { data, done in clientConn.sendBinary(data, completion: done) },
            complete: { id in clientConn.send(.fileComplete(id: id)) },
            done: {})

        expect(recvSem.wait(timeout: .now() + 15) == .success, "receiver completed the file within 15s")
        guard let outURL = recvURLBox.value else { return fail("no received file URL") }
        let outBytes = try Data(contentsOf: outURL)
        expect(outBytes.count == payloadSize,
               "received byte count == source (\(outBytes.count) vs \(payloadSize))")
        expect(outBytes == srcBytes, "received bytes are byte-for-byte identical to source")
        log("stage8 ok: file \(outBytes.count) bytes round-trip intact")
        try? FileManager.default.removeItem(at: srcURL)
        try? FileManager.default.removeItem(at: outURL)

        // ---- Cleanup -----------------------------------------------------------------
        clientConn.cancel()
        inboundConnections.cancelAll()
        server.stop()

        print("ALL PASS")
    }

    // MARK: - Helpers

    @discardableResult
    static func waitUntil(timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return cond()
    }

    static func isReady(_ s: NWConnection.State) -> Bool {
        if case .ready = s { return true }
        return false
    }

    static func describe(_ s: NWConnection.State) -> String {
        switch s {
        case .setup: return "setup"
        case .waiting(let e): return "waiting(\(e))"
        case .preparing: return "preparing"
        case .ready: return "ready"
        case .failed(let e): return "failed(\(e))"
        case .cancelled: return "cancelled"
        @unknown default: return "unknown"
        }
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if let ipv4 = IPv4Address(normalized) {
            return ipv4.rawValue.first == 127
        }
        if let ipv6 = IPv6Address(normalized) {
            let bytes = [UInt8](ipv6.rawValue)
            let isIPv6Loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let isMappedIPv4Loopback = bytes.prefix(10).allSatisfy { $0 == 0 }
                && bytes[10] == 0xff && bytes[11] == 0xff && bytes[12] == 127
            return isIPv6Loopback || isMappedIPv4Loopback
        }
        return false
    }

    static func log(_ m: String) { FileHandle.standardError.write(Data("• \(m)\n".utf8)) }

    static func expect(_ c: Bool, _ m: String) {
        if !c { fail(m) }
    }

    static func fail(_ m: String) {
        FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8))
        exit(1)
    }
}
