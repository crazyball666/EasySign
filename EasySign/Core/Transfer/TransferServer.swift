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

    private let metadataLock = NSLock()
    private var _peerFingerprint: String?
    private var _remoteHost: String?
    /// 由本连接在 `.ready` 时从自身 TLS metadata 读出对端叶证书指纹后写入(在连接队列上)。
    /// 读取应发生在 `.ready` 之后。用锁保证跨线程可见且不撕裂。
    var peerFingerprint: String? {
        metadataLock.lock(); defer { metadataLock.unlock() }
        return _peerFingerprint
    }
    /// `.ready` 时从已解析的实际远端 endpoint 捕获；Bonjour service 等不可安全直连的 endpoint 返回 nil。
    var remoteHost: String? {
        metadataLock.lock(); defer { metadataLock.unlock() }
        return _remoteHost
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
            if case .ready = st {
                let remoteEndpoint = self.nw.currentPath?.remoteEndpoint ?? self.nw.endpoint
                self.publishReadyMetadata(
                    peerFingerprint: self.readPeerFingerprint(),
                    remoteHost: TransferTrustedEndpoint.host(from: remoteEndpoint)
                )
            }
            self._lastState = st
            self._stateHandler?(st)
        }
        nw.start(queue: queue)
        receiveLoop()
    }

    private func publishReadyMetadata(peerFingerprint: String?, remoteHost: String?) {
        metadataLock.lock()
        _peerFingerprint = peerFingerprint
        _remoteHost = remoteHost
        metadataLock.unlock()
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

    /// `completion` 在本帧被 Network.framework 接收处理(写入协议栈)后回调,供需要"先冲刷再关闭"的场景使用
    /// (如断开前的 .bye)。默认 no-op,既有调用方无需改动。
    func send(_ msg: WireMessage, completion: @escaping (NWError?) -> Void = { _ in }) {
        guard let data = try? msg.encoded() else { completion(nil); return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "msg", metadata: [meta])
        nw.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { completion($0) })
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
    // 并发模型:所有可变状态(listener / lastState / port / portPolicy / advertising)只在 `queue` 上读写——
    // 该串行队列就是 NWListener 的回调队列,始终被 Network.framework 服务,不依赖主线程 runloop 被泵。
    // 公开方法(start/restart/restartIfUnhealthy/setAdvertising/stop)都把改动派发到 `queue`;start 用
    // queue.sync 以便把构造错误同步抛回调用方。stateUpdateHandler 本就在 `queue` 上,直接改状态、不再 hop。
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "transfer.server")
    private let identity: () throws -> SecIdentity
    private var advertising = false           // 期望的广播开关:restart 后据此恢复(而非每次重读外部状态)
    private var lastState: NWListener.State?   // 最近一次 listener 状态(queue;供 restartIfUnhealthy 判断)
    private var stopped = false                // stop() 后置位:阻止挂起的退避重试/自愈再拉起 listener
    private var portPolicy: TransferListenerPortPolicy

    var onConnection: ((TransferConnection) -> Void)?
    /// listener 状态变化(在 `queue` 上回调,带当前监听端口)。上层据此更新 @Published listenPort(自行切主线程)、感知掉线。
    var onStateChange: ((NWListener.State, UInt16?) -> Void)?
    private(set) var port: UInt16?

    /// Bonjour 广播信息(deviceId/name/fingerprint)。queue 私有;经 setAdvertiseInfo 写入,applyAdvertising 读取。
    private var advertiseInfo: (deviceId: String, name: String, fingerprint: String)?

    init(identity: @escaping () throws -> SecIdentity, preferredPort: UInt16? = nil) {
        self.identity = identity
        self.portPolicy = TransferListenerPortPolicy(preferredPort: preferredPort)
    }

    /// 设置/更新 Bonjour 广播信息(deviceId/name/fingerprint)。任意线程调用,改动派发到 `queue`。
    /// 改名后需再调用 setAdvertising(true) 才会用新 TXT 重新广播。
    func setAdvertiseInfo(_ info: (deviceId: String, name: String, fingerprint: String)?) {
        queue.async { [weak self] in self?.advertiseInfo = info }
    }

    /// 首次启动:在 `queue` 上同步构造,失败抛回调用方以便启动流程感知。
    func start() throws { try queue.sync { try makeListener() } }

    /// 在 `queue` 上构造并启动 listener。仅由 start()/restart() 在 `queue` 上调用。
    private func makeListener() throws {
        let id = try identity()
        // verify block 对所有入站连接共享,只做"放行";指纹由每条连接自己从 metadata 读取。
        let params = TransferTLS.parameters(identity: id, pin: .acceptAny)
        let binding = portPolicy.nextBinding
        let requestedPort: UInt16?
        let listener: NWListener
        switch binding {
        case .random:
            requestedPort = nil
            listener = try NWListener(using: params)
        case .preferred(let rawPort):
            requestedPort = rawPort
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: rawPort)!)
        }
        listener.newConnectionHandler = { [weak self] nw in
            guard let self else { return }
            let conn = TransferConnection(nw, queue: self.queue)
            conn.start()
            self.onConnection?(conn)
        }
        listener.stateUpdateHandler = { [weak self] st in
            guard let self else { return }   // 已在 `queue` 上(listener.start(queue:)),直接改状态
            // 已被 restart 顶替的旧 listener 的迟到回调(尤其 cancel 后的 .cancelled)直接丢弃,
            // 否则会把刚换上的新 listener 的状态/端口覆盖回旧值。makeListener 在本队列上同步设好 self.listener。
            guard self.listener === listener else { return }
            self.lastState = st
            if case .ready = st {
                self.port = listener.port?.rawValue
                if let port = self.port {
                    self.portPolicy.listenerReady(port: port)
                }
            }
            // 自愈:系统睡眠/网络变更常把 listener 打到 .failed(终态,不会自行恢复)→ 退避后重建。
            // 否则醒来后本机既无法被连入、Bonjour 广播也随之消失,对端永远发现不到本机(单向重连死锁的一半)。
            // 退避期间若已被外部 restart 顶替(listener 已换),则跳过,避免把刚起来的监听又拆掉。
            if case .failed(let error) = st {
                let failureKind = TransferListenerPortPolicy.failureKind(for: error)
                let nextBinding = self.portPolicy.listenerFailed(
                    requestedPort: requestedPort,
                    kind: failureKind
                )
                let shouldFallBackImmediately = requestedPort != nil
                    && failureKind == .addressInUse
                    && nextBinding == .random
                let retryDelay: TimeInterval = shouldFallBackImmediately ? 0 : 2
                self.queue.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                    guard let self, self.listener === listener else { return }
                    self.makeListenerReplacing()
                }
            }
            self.onStateChange?(st, self.port)
        }
        listener.start(queue: queue)
        self.listener = listener
        applyAdvertising()   // 重建后按期望值恢复广播(从 advertiseInfo 现取现建 TXT/SRV)
    }

    /// 在 `queue` 上拆旧建新(供自愈/重连复用)。构造失败则退避重试。
    /// `stopped` 守卫:stop() 之后任何挂起的退避重试 / 自愈回调都不得再把 listener 拉起来。
    private func makeListenerReplacing() {
        guard !stopped else { return }
        listener?.cancel(); listener = nil; lastState = nil
        do { try makeListener() }
        catch { queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.makeListenerReplacing() } }
    }

    /// 监听若已掉到终态(.failed/.cancelled)或从未起来就重建;.ready/.waiting/.setup 不动
    /// (.waiting 会在网络恢复后自行回到 .ready,重建只会平添换端口)。睡醒/回前台时调用。
    func restartIfUnhealthy() {
        queue.async { [weak self] in
            guard let self else { return }
            switch self.lastState {
            case .ready, .waiting, .setup: return
            case .failed, .cancelled, .none: self.makeListenerReplacing()
            @unknown default: self.makeListenerReplacing()
            }
        }
    }

    /// 开关 Bonjour 广播。每次开启都从当前 `advertiseInfo` 重建 service/TXT,
    /// 故改名(setDeviceName 更新 advertiseInfo)后再调用即可更新广播的 name。任意线程调用。
    func setAdvertising(_ on: Bool) {
        queue.async { [weak self] in self?.advertising = on; self?.applyAdvertising() }
    }

    /// 在 `queue` 上按 advertising/advertiseInfo 重建 listener.service。
    private func applyAdvertising() {
        guard let listener else { return }
        if advertising, let info = advertiseInfo {
            var txt = NWTXTRecord()
            txt["deviceId"] = info.deviceId
            txt["name"] = info.name
            txt["fp"] = info.fingerprint
            listener.service = NWListener.Service(name: info.deviceId, type: PeerDiscovery.serviceType, txtRecord: txt)
        } else {
            listener.service = nil
        }
    }

    /// 停止监听。强持有 self 入队,保证即便上层随即丢弃引用,清理仍会执行。
    /// 置 `stopped`:挡住任何挂起的退避重试 / 自愈把 listener 重新拉起来。
    func stop() {
        queue.async { self.stopped = true; self.listener?.cancel(); self.listener = nil; self.lastState = nil; self.advertising = false }
    }
}
