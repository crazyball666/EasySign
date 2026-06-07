import Foundation
import Network
import Security

/// Reproduction harness for the REAL "发现的设备 → 连接" path that the host:port loopback
/// test never covers. The UI's discovered-peer button calls `connect(endpoint:)` with a
/// **Bonjour service endpoint** (NWBrowser.Result.endpoint), not a ws:// URL. This test:
///   1. brings up a TransferServer advertising over Bonjour,
///   2. discovers it via the real PeerDiscovery (NWBrowser),
///   3. connects through TransferClient.connect(endpoint:) — the exact failing path,
///   4. asserts BOTH ends reach .ready AND the SERVER reads the client's leaf fingerprint
///      (mutual TLS) — the precondition for inboundReady to ever show a pairing code.
///
/// If the server fingerprint comes back nil, this reproduces "对端不弹配对码".

final class Box<T> {
    private let lock = NSLock()
    private var v: T
    init(_ initial: T) { v = initial }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ n: T) { lock.lock(); v = n; lock.unlock() }
}

@main
struct TransferBonjourEndpointTests {
    static func main() {
        do { try run() } catch { fail("threw: \(error)") }
    }

    static func run() throws {
        let matA = try DeviceIdentity.generateSelfSigned(commonName: "EasySign-A")   // client
        let matB = try DeviceIdentity.generateSelfSigned(commonName: "EasySign-B")   // server
        let idA = try DeviceIdentity.importIdentity(certDER: matA.certDER, keyX963: matA.keyX963)
        let idB = try DeviceIdentity.importIdentity(certDER: matB.certDER, keyX963: matB.keyX963)
        log("idA(client)=\(idA.fingerprint.prefix(8))…  idB(server)=\(idB.fingerprint.prefix(8))…")

        // ---- Server advertises over Bonjour ------------------------------------------
        let serverDeviceId = "server-dev-\(getpid())"
        let server = TransferServer(identity: { idB.identity })
        let serverConn = Box<TransferConnection?>(nil)
        let serverConnSem = DispatchSemaphore(value: 0)
        server.onConnection = { conn in
            if serverConn.value == nil { serverConn.set(conn); serverConnSem.signal() }
        }
        server.advertiseInfo = (deviceId: serverDeviceId, name: "ServerMac", fingerprint: idB.fingerprint)
        try server.start()
        expect(waitUntil(timeout: 10) { server.port != nil }, "server bound a port")
        server.setAdvertising(true)
        log("server listening on :\(server.port!), advertising deviceId=\(serverDeviceId)")

        // ---- Discover it via real NWBrowser (selfDeviceId differs so it's not filtered) -
        let discovery = PeerDiscovery(selfDeviceId: { "client-dev-\(getpid())" })
        let foundPeer = Box<DiscoveredPeer?>(nil)
        let foundSem = DispatchSemaphore(value: 0)
        discovery.onPeersChanged = { peers in
            if let p = peers.first(where: { $0.deviceId == serverDeviceId }), foundPeer.value == nil {
                foundPeer.set(p); foundSem.signal()
            }
        }
        discovery.start()
        guard foundSem.wait(timeout: .now() + 15) == .success, let peer = foundPeer.value else {
            return fail("Bonjour discovery never found the advertised server within 15s")
        }
        log("discovered peer endpoint = \(peer.endpoint)")

        // ---- Connect via the EXACT failing path: connect(endpoint:) -------------------
        let client = TransferClient(identity: { idA.identity })
        let clientConn = try client.connect(endpoint: peer.endpoint, pin: .acceptAny)
        expect(serverConnSem.wait(timeout: .now() + 10) == .success,
               "server accepted an inbound connection from the Bonjour-endpoint client")
        guard let sConn = serverConn.value else { return fail("no server-side connection captured") }

        // ---- The crux: does BOTH sides capture a fingerprint over the Bonjour path? ----
        let clientReady = waitUntil(timeout: 12) { clientConn.peerFingerprint != nil }
        let serverReady = waitUntil(timeout: 12) { sConn.peerFingerprint != nil }

        log("client reached .ready & read server fp: \(clientReady) (\(clientConn.peerFingerprint?.prefix(8) ?? "nil"))")
        log("server reached .ready & read client fp: \(serverReady) (\(sConn.peerFingerprint?.prefix(8) ?? "nil"))")

        expect(clientReady, "CLIENT captured a peer fingerprint over Bonjour endpoint")
        expect(clientConn.peerFingerprint == idB.fingerprint,
               "client fp == server idB (got \(clientConn.peerFingerprint?.prefix(8) ?? "nil"))")
        // This is the assertion that mirrors inboundReady's `guard let fp` on the real device:
        expect(serverReady, "SERVER captured the client fingerprint over Bonjour endpoint (inboundReady precondition)")
        expect(sConn.peerFingerprint == idA.fingerprint,
               "server fp == client idA (got \(sConn.peerFingerprint?.prefix(8) ?? "nil"))")

        // ---- Full pairing over the SAME Bonjour connection (the 常驻 flow: connect WITH a code) ----
        // Mirrors the real app: client gets the server's displayed code and pairs; no cancel, no race.
        let code = PairingCrypto.makeCode()
        let pmA = PairingManager(code: code, selfFingerprint: idA.fingerprint,
                                 selfDeviceId: "device-A", selfName: "ClientMac",
                                 peerFingerprint: clientConn.peerFingerprint!)
        let pmB = PairingManager(code: code, selfFingerprint: idB.fingerprint,
                                 selfDeviceId: "device-B", selfName: "ServerMac",
                                 peerFingerprint: sConn.peerFingerprint!)
        let outA = Box<PairingManager.Outcome?>(nil), outB = Box<PairingManager.Outcome?>(nil)
        let semA = DispatchSemaphore(value: 0), semB = DispatchSemaphore(value: 0)
        pmA.send = { clientConn.send($0) }; pmB.send = { sConn.send($0) }
        pmA.onOutcome = { outA.set($0); semA.signal() }
        pmB.onOutcome = { outB.set($0); semB.signal() }
        clientConn.onMessage = { pmA.handle($0) }; sConn.onMessage = { pmB.handle($0) }
        pmA.begin(); pmB.begin()
        expect(semA.wait(timeout: .now() + 10) == .success, "client pairing produced an outcome")
        expect(semB.wait(timeout: .now() + 10) == .success, "server pairing produced an outcome")
        guard case .success = outA.value else { return fail("client pairing not success: \(String(describing: outA.value))") }
        guard case .success = outB.value else { return fail("server pairing not success: \(String(describing: outB.value))") }
        log("pairing over Bonjour endpoint succeeded (code=\(code))")

        clientConn.cancel(); sConn.cancel(); discovery.stop(); server.stop()
        print("ALL PASS")
    }

    // MARK: - Helpers
    @discardableResult
    static func waitUntil(timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if cond() { return true }; Thread.sleep(forTimeInterval: 0.02) }
        return cond()
    }
    static func log(_ m: String) { FileHandle.standardError.write(Data("• \(m)\n".utf8)) }
    static func expect(_ c: Bool, _ m: String) { if !c { fail(m) } }
    static func fail(_ m: String) {
        FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); exit(1)
    }
}
