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

    private var _binaryHandler: ((Data) -> Void)?
    private var _binaryBuffer: [Data] = []
    private var _binaryBufferedBytes = 0
    private static let maxPreHandlerBuffer = 16 * 1024 * 1024   // 16 MB
    /// 二进制(WS .binary 帧)入口,机制与 onMessage 镜像:queue-confined、设置前缓存、设置时回放。
    var onBinary: ((Data) -> Void)? {
        get { queue.sync { _binaryHandler } }
        set {
            queue.async {
                self._binaryHandler = newValue
                guard let h = newValue, !self._binaryBuffer.isEmpty else { return }
                let pending = self._binaryBuffer; self._binaryBuffer.removeAll()
                self._binaryBufferedBytes = 0
                for d in pending { h(d) }
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

    /// 以 WS .binary 帧发送原始字节(文件/图片分块)。
    /// `completion` 在本块被 Network.framework 接收处理后回调,供发送侧做背压。
    func sendBinary(_ data: Data, completion: @escaping () -> Void = {}) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "bin", metadata: [meta])
        nw.send(content: data, contentContext: ctx, isComplete: true,
                completion: .contentProcessed { _ in completion() })
    }

    func cancel() { nw.cancel() }

    private func receiveLoop() {
        nw.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self else { return }
            // 读 WS opcode 区分 .binary / text / 控制帧;completion 已在本连接 queue 上,
            // 故可直接访问 _binaryHandler/_binaryBuffer 与 _handler/_buffer(无需再 hop)。
            let wsMeta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            // 对端发来 WebSocket close 帧:优雅关闭。主动 cancel → 触发 .cancelled,让上层收尾。
            if wsMeta?.opcode == .close { self.nw.cancel(); return }
            if let data, !data.isEmpty {
                if wsMeta?.opcode == .binary {
                    if let h = self._binaryHandler {
                        h(data)
                    } else {
                        self._binaryBufferedBytes += data.count
                        if self._binaryBufferedBytes > Self.maxPreHandlerBuffer {
                            self.nw.cancel()
                            return
                        }
                        self._binaryBuffer.append(data)
                    }
                } else if let msg = try? WireMessage.decode(data) {
                    if let h = self._handler { h(msg) } else { self._buffer.append(msg) }
                }
            }
            // 终态:硬错误,或读端 EOF(对端发 FIN / 进程退出 / 对端 nw.cancel())。
            // EOF 判据 = 无数据 + 无 context + isComplete + 无 error;控制帧(ping/pong)带 context,
            // 不会被误判为 EOF。主动 cancel() 把"对端已走"统一收敛成 .cancelled,
            // 复用既有 onStateChange → handleConnectedDrop 的断开收尾/重连逻辑。
            // (旧实现只看 error==nil 就重新 arm,优雅关闭的 EOF 被当成"继续收" → 永不感知断开。)
            if error != nil || (isComplete && data == nil && context == nil) {
                self.nw.cancel()
                return
            }
            self.receiveLoop()
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

    /// Bonjour 广播信息(deviceId/name/fingerprint)。`setAdvertising(true)` 每次都按当前值重建 TXT。
    var advertiseInfo: (deviceId: String, name: String, fingerprint: String)?

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
        // 广播由调用方在 start() 之后用 setAdvertising(!stealth) 触发,从 advertiseInfo 现取现建,
        // 这样 setDeviceName 改名后再调用即可反映新的 TXT name。
    }

    /// 开关 Bonjour 广播。每次开启都从当前 `advertiseInfo` 重建 service/TXT,
    /// 故改名(setDeviceName 更新 advertiseInfo)后再调用即可更新广播的 name。
    func setAdvertising(_ on: Bool) {
        guard let listener else { return }
        if on, let info = advertiseInfo {
            var txt = NWTXTRecord()
            txt["deviceId"] = info.deviceId
            txt["name"] = info.name
            txt["fp"] = info.fingerprint
            listener.service = NWListener.Service(name: info.deviceId, type: PeerDiscovery.serviceType, txtRecord: txt)
        } else {
            listener.service = nil
        }
    }

    func stop() { listener?.cancel(); listener = nil }
}
