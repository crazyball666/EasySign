import Foundation
import Network

/// 一条连接(server 或 client 侧通用)。
final class TransferConnection {
    let nw: NWConnection
    var onMessage: ((WireMessage) -> Void)?
    var onStateChange: ((NWConnection.State) -> Void)?

    private let fpLock = NSLock()
    private var _peerFingerprint: String?
    /// 由 TLS 验证回调(capture 模式)在握手期写入;读取应发生在 `.ready` 之后。
    /// 用锁保证跨线程(verify 队列写、业务队列读)可见且不撕裂。
    var peerFingerprint: String? {
        get { fpLock.lock(); defer { fpLock.unlock() }; return _peerFingerprint }
        set { fpLock.lock(); _peerFingerprint = newValue; fpLock.unlock() }
    }

    private let queue: DispatchQueue

    init(_ nw: NWConnection, queue: DispatchQueue) {
        self.nw = nw
        self.queue = queue
    }

    func start() {
        nw.stateUpdateHandler = { [weak self] st in self?.onStateChange?(st) }
        nw.start(queue: queue)
        receiveLoop()
    }

    func send(_ msg: WireMessage) {
        guard let data = try? msg.encoded() else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "msg", metadata: [meta])
        nw.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    func cancel() { nw.cancel() }

    private func receiveLoop() {
        nw.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty, let msg = try? WireMessage.decode(data) {
                self.onMessage?(msg)
            }
            if error == nil { self.receiveLoop() }
        }
    }
}

/// 监听入站连接。Phase 1:server 以 `.capture` 模式起(放行任意对端 + 捕获指纹),
/// 由上层依据是否已配对/配对结果决定后续处理。
final class TransferServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "transfer.server")
    private let identity: () throws -> SecIdentity

    var onConnection: ((TransferConnection) -> Void)?
    private(set) var port: UInt16?

    // 把 TLS 验证回调捕获到的指纹写回"当前正在握手"的那条连接。
    // NWListener 的 params(含 verify block)是所有入站连接共享的,无法做到 per-connection
    // 的 verify block,因此只能用一个共享槽位转交指纹。newConnectionHandler 在串行
    // 队列上交付连接,我们在交付时把 pendingConn 指向该连接;verify block 随后(在另一条
    // verify 队列上)读取并写回。Phase 1 假设"两台已知机器 + 同一时刻仅一次配对",该窗口
    // 可接受。用锁保证 pendingConn 的跨线程可见性。
    private let pendingLock = NSLock()
    private weak var pendingConn: TransferConnection?

    init(identity: @escaping () throws -> SecIdentity) {
        self.identity = identity
    }

    func start() throws {
        let id = try identity()
        let params = TransferTLS.parameters(identity: id, pin: .capture { [weak self] fp in
            guard let self else { return }
            self.pendingLock.lock()
            self.pendingConn?.peerFingerprint = fp
            self.pendingLock.unlock()
        })
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] nw in
            guard let self else { return }
            let conn = TransferConnection(nw, queue: self.queue)
            self.pendingLock.lock()
            self.pendingConn = conn   // capture 回调会写到这条连接
            self.pendingLock.unlock()
            conn.start()
            self.onConnection?(conn)
        }
        listener.stateUpdateHandler = { [weak self] st in
            if case .ready = st { self?.port = listener.port?.rawValue }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() { listener?.cancel(); listener = nil }
}
