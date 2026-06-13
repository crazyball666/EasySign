import Foundation
import Network

/// 坐实根因:一方断开后,另一方能否"感知"。
///
/// 复刻线上现象:A、B 建立连接后,B 优雅断开(用户点「断开」/退出 App → nw.cancel() → 发 FIN,
/// 或进程退出由内核发 FIN)。此时 A 端的 NWConnection 状态机**不会**自动转 .failed/.cancelled
/// (Network.framework 经典坑:对端优雅关闭只是读端 EOF,连接仍 .ready,半关闭仍可写),
/// 而 TransferConnection.receiveLoop 又把 EOF(data=nil & error=nil)当「没事,继续收」重新 arm,
/// 于是 A 端 onStateChange 永不触发终态 → 上层 handleConnectedDrop 永不收尾 → 一直显示「已连接」。
///
/// 本测试:建立连接 → 一端 cancel() → 断言另一端在 8s 内收到终态(.failed/.cancelled)。
/// 修复前:永不触发 → FAIL。修复后:receiveLoop 检测 EOF/close/error → nw.cancel() → .cancelled → PASS。
///
/// 期望输出:`ALL PASS`,否则 `FAIL: ...` 到 stderr + exit(1)。

/// 线程安全的「最新值」盒子(回调在 Network.framework 队列上触发,main 阻塞等待)。
final class Latest<T> {
    private let lock = NSLock()
    private var v: T
    init(_ initial: T) { v = initial }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ n: T) { lock.lock(); v = n; lock.unlock() }
}

@main
struct TransferDisconnectDetectionTests {
    static func main() {
        do { try run() } catch { fail("threw: \(error)") }
    }

    static func run() throws {
        // —— 两套自签身份 ——
        let matA = try DeviceIdentity.generateSelfSigned(commonName: "EasySign-A")
        let matB = try DeviceIdentity.generateSelfSigned(commonName: "EasySign-B")
        let idA = try DeviceIdentity.importIdentity(certDER: matA.certDER, keyX963: matA.keyX963)
        let idB = try DeviceIdentity.importIdentity(certDER: matB.certDER, keyX963: matB.keyX963)

        // —— 起服务端(idB)——
        let server = TransferServer(identity: { idB.identity })
        let serverConnBox = Latest<TransferConnection?>(nil)
        let serverConnSem = DispatchSemaphore(value: 0)
        server.onConnection = { conn in
            if serverConnBox.value == nil { serverConnBox.set(conn); serverConnSem.signal() }
        }
        try server.start()
        expect(waitUntil(timeout: 10) { server.port != nil }, "server bound a port")
        let port = server.port!
        log("server listening on 127.0.0.1:\(port)")

        // —— 客户端(idA)连入 ——
        let client = TransferClient(identity: { idA.identity })
        let clientConn = try client.connect(host: "127.0.0.1", port: port, pin: .acceptAny)
        expect(serverConnSem.wait(timeout: .now() + 10) == .success, "server accepted a connection")
        let serverConn = serverConnBox.value!

        expect(waitUntil(timeout: 10) { clientConn.peerFingerprint != nil && serverConn.peerFingerprint != nil },
               "both sides reached .ready (mutual TLS)")
        log("both sides connected & ready")

        // —— 在「服务端」连接上挂终态捕获(setter 会立刻回放当前 .ready,只记录终态)——
        let terminalSem = DispatchSemaphore(value: 0)
        let terminal = Latest<String?>(nil)
        serverConn.onStateChange = { st in
            switch st {
            case .failed(let e): terminal.set("failed(\(e))"); terminalSem.signal()
            case .cancelled:     terminal.set("cancelled");    terminalSem.signal()
            default:             break
            }
        }

        // —— 客户端优雅断开(等同用户点「断开」/退出 App)——
        log("client disconnecting (cancel) …")
        clientConn.cancel()

        // —— 服务端必须在数秒内感知到对端已走。Bug:永不感知 → 一直 .ready。——
        let noticed = terminalSem.wait(timeout: .now() + 8) == .success
        expect(noticed, "server detected peer disconnect within 8s (got: \(terminal.value ?? "nothing — still thinks it's connected"))")
        log("server noticed peer gone: \(terminal.value ?? "—")")

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

    static func log(_ m: String) { FileHandle.standardError.write(Data("• \(m)\n".utf8)) }

    static func expect(_ c: Bool, _ m: String) { if !c { fail(m) } }

    static func fail(_ m: String) {
        FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8))
        exit(1)
    }
}
