import Foundation
import Network
import Security

/// 一条连接(server 或 client 侧通用)。
final class TransferConnection {
    let nw: NWConnection

    private var _stateHandler: ((NWConnection.State) -> Void)?
    private var _lastState: NWConnection.State?
    /// 赋值即生效;若连接已处于某状态(如 .ready),立即回放最后一次状态。setter 线程安全。
    var onStateChange: ((NWConnection.State) -> Void)? {
        get { queue.sync { _stateHandler } }
        set {
            queue.async {
                self._stateHandler = newValue
                if let h = newValue, let s = self._lastState { h(s) }
            }
        }
    }

    private var _handler: ((WireMessage) -> Void)?
    private var _buffer: [WireMessage] = []
    /// 赋值即开始接收。在 handler 设置前到达的消息会被缓存,设置时按序回放。
    /// setter 线程安全(任意线程可调)。
    var onMessage: ((WireMessage) -> Void)? {
        get { queue.sync { _handler } }
        set {
            queue.async {
                self._handler = newValue
                guard let h = newValue, !self._buffer.isEmpty else { return }
                let pending = self._buffer
                self._buffer.removeAll()
                for m in pending { h(m) }
            }
        }
    }

    private let fpLock = NSLock()
    private var _peerFingerprint: String?
    /// 由本连接在 `.ready` 时从自身 TLS metadata 读出对端叶证书指纹后写入(在连接队列上)。
    /// 读取应发生在 `.ready` 之后。用锁保证跨线程可见且不撕裂。
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
        nw.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            // 握手完成后,从本连接自己协商出的 TLS metadata 取对端指纹——
            // 无共享槽位、无跨连接错配、无竞态。必须在回调上层 onStateChange 之前写好。
            if case .ready = st { self.peerFingerprint = self.readPeerFingerprint() }
            self._lastState = st
            self._stateHandler?(st)
        }
        nw.start(queue: queue)
        receiveLoop()
    }

    /// 从本连接已协商的 TLS metadata 取对端证书链的叶证书(index 0)DER 的 SHA-256 hex。
    private func readPeerFingerprint() -> String? {
        guard let meta = nw.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        else { return nil }
        let secMeta = meta.securityProtocolMetadata
        var leafDER: Data?
        sec_protocol_metadata_access_peer_certificate_chain(secMeta) { secCert in
            if leafDER == nil {  // 证书链中第一张即叶证书
                let certRef = sec_certificate_copy_ref(secCert).takeRetainedValue()
                leafDER = SecCertificateCopyData(certRef) as Data
            }
        }
        guard let der = leafDER else { return nil }
        return CertFingerprint.sha256Hex(of: der)
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
                if let h = self._handler { h(msg) } else { self._buffer.append(msg) }
            }
            if error == nil { self.receiveLoop() }
        }
    }
}

/// 监听入站连接。Phase 1:server 以 `.acceptAny` 起(放行任意对端,应用层 HMAC 鉴权),
/// 每条连接在 `.ready` 后从自身 TLS metadata 自取对端指纹,由上层依据配对状态决定后续处理。
final class TransferServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "transfer.server")
    private let identity: () throws -> SecIdentity

    var onConnection: ((TransferConnection) -> Void)?
    private(set) var port: UInt16?

    init(identity: @escaping () throws -> SecIdentity) {
        self.identity = identity
    }

    func start() throws {
        let id = try identity()
        // verify block 对所有入站连接共享,只做"放行";指纹由每条连接自己从 metadata 读取。
        let params = TransferTLS.parameters(identity: id, pin: .acceptAny)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] nw in
            guard let self else { return }
            let conn = TransferConnection(nw, queue: self.queue)
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
