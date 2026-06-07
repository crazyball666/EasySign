import Foundation
import Network
import Security

/// Standalone loopback integration test for the secure-channel + pairing stack.
/// Exercises the REAL Network.framework + Security stack over 127.0.0.1:
///   1. two self-signed identities (distinct fingerprints)
///   2. mutual-TLS handshake + per-connection peer fingerprint capture (C4 design)
///   3. symmetric PairingManager handshake -> mutual success
///   4. clipboard WireMessage delivery over the established channel
///   5. TLS pinning rejects a wrong-fingerprint client (negative test)
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

@main
struct TransferLoopbackTests {
    static func main() {
        do { try run() } catch { fail("threw: \(error)") }
    }

    static func run() throws {
        // ---- Stage 1: two identities -------------------------------------------------
        let matA = try DeviceIdentity.generateSelfSigned(commonName: "EasySign-A")
        let matB = try DeviceIdentity.generateSelfSigned(commonName: "EasySign-B")
        let idA = try DeviceIdentity.importIdentity(p12Data: matA.p12Data, passphrase: matA.passphrase)
        let idB = try DeviceIdentity.importIdentity(p12Data: matB.p12Data, passphrase: matB.passphrase)
        expect(idA.fingerprint.count == 64 && idB.fingerprint.count == 64,
               "fingerprints are 64 hex chars")
        expect(idA.fingerprint != idB.fingerprint, "two identities have distinct fingerprints")
        log("stage1 ok: idA=\(idA.fingerprint.prefix(8))… idB=\(idB.fingerprint.prefix(8))…")

        // ---- Bring up server (idB) ---------------------------------------------------
        let server = TransferServer(identity: { idB.identity })
        let serverConnHolder = Latest<TransferConnection?>(nil)
        let serverConnSem = DispatchSemaphore(value: 0)
        server.onConnection = { conn in
            // onConnection fires on the server queue (serial) -> capture the FIRST only.
            if serverConnHolder.value == nil {
                serverConnHolder.set(conn)
                serverConnSem.signal()
            }
        }
        try server.start()
        expect(waitUntil(timeout: 10) { server.port != nil }, "server bound a port")
        let port = server.port!
        log("server listening on 127.0.0.1:\(port)")

        // ---- Client (idA) connects with .acceptAny ----------------------------------
        let client = TransferClient(identity: { idA.identity })
        let clientConn = try client.connect(host: "127.0.0.1", port: port, pin: .acceptAny)
        expect(serverConnSem.wait(timeout: .now() + 10) == .success, "server accepted a connection")
        let serverConn = serverConnHolder.value!

        // ---- Stage 2: TLS ready + per-connection fingerprint capture -----------------
        let bothReady = waitUntil(timeout: 10) {
            clientConn.peerFingerprint != nil && serverConn.peerFingerprint != nil
        }
        expect(bothReady, "both connections reached .ready with a captured peer fingerprint")
        expect(clientConn.peerFingerprint == idB.fingerprint,
               "client captured server(idB) fingerprint, got \(clientConn.peerFingerprint ?? "nil")")
        expect(serverConn.peerFingerprint == idA.fingerprint,
               "server captured client(idA) fingerprint, got \(serverConn.peerFingerprint ?? "nil")")
        log("stage2 ok: mutual TLS + per-connection fingerprint capture verified")

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

        // ---- Stage 4: clipboard message delivery ------------------------------------
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
        log("stage4 ok: clipboard message delivered intact")

        // ---- Stage 5: pinning rejects a stranger (negative) -------------------------
        let wrongFp = String(repeating: "0", count: 64)
        expect(wrongFp != idB.fingerprint, "wrong pin differs from the real server fingerprint")
        let client2 = TransferClient(identity: { idA.identity })
        let badConn = try client2.connect(host: "127.0.0.1", port: port,
                                          pin: .requirePinned(fingerprint: wrongFp))
        // Poll the connection's own state (race-free vs. callback assignment ordering).
        let decisive = waitUntil(timeout: 10) {
            isReady(badConn.nw.state) || isBlocked(badConn.nw.state)
        }
        expect(decisive, "pinned-wrong connection reached a decisive state within timeout")
        let finalState = badConn.nw.state
        expect(!isReady(finalState),
               "pinned-wrong connection must NOT reach .ready (state=\(describe(finalState)))")
        expect(isBlocked(finalState),
               "pinned-wrong connection blocked (failed/waiting/cancelled), state=\(describe(finalState))")
        expect(badConn.peerFingerprint == nil, "blocked connection captured no peer fingerprint")
        log("stage5 ok: TLS pinning blocked the wrong-fingerprint client (state=\(describe(finalState)))")

        // ---- Cleanup -----------------------------------------------------------------
        badConn.cancel()
        clientConn.cancel()
        serverConn.cancel()
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

    static func isBlocked(_ s: NWConnection.State) -> Bool {
        switch s {
        case .failed, .waiting, .cancelled: return true
        default: return false
        }
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

    static func log(_ m: String) { FileHandle.standardError.write(Data("• \(m)\n".utf8)) }

    static func expect(_ c: Bool, _ m: String) {
        if !c { fail(m) }
    }

    static func fail(_ m: String) {
        FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8))
        exit(1)
    }
}
