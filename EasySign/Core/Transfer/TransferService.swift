import Foundation
import Network
import Security

/// 互传服务门面。串联身份 / 监听 / 连接 / 剪贴板 / 配对,持有 @Published 状态供 UI 观察。
/// 设计要点:剪贴板同步、收消息不依赖主窗口(本对象活在 ServiceHub,App 生命周期)。
final class TransferService: ObservableObject {
    let logger: LoggerService

    @Published var connectionState: ConnectionState = .idle
    @Published var clipboardSyncEnabled = false
    @Published var history: [TransferItem] = []
    @Published var pendingPairingCode: String?      // 本机被连时显示给对方输入
    @Published var pairedPeers: [PairedPeer] = []
    @Published var listenPort: UInt16?

    private let identityStore = DeviceIdentityStore()
    private let peerStore = PairedPeerStore()
    private let monitor = ClipboardMonitor()
    private var server: TransferServer?
    private var client: TransferClient?
    private var loadedIdentity: DeviceIdentity.Loaded?
    private var activeConn: TransferConnection?
    private var activePairing: PairingManager?
    private var failureCounts: [String: Int] = [:]
    private var cooldownUntil: [String: Date] = [:]

    init(logger: LoggerService) {
        self.logger = logger
        self.pairedPeers = peerStore.all()
        monitor.onLocalText = { [weak self] text, hash in
            DispatchQueue.main.async { self?.handleLocalClipboard(text: text, hash: hash) }
        }
    }

    var deviceName: String { identityStore.deviceName }

    // MARK: - 生命周期

    func start() {
        do {
            let id = try identity()
            let server = TransferServer(identity: { try self.identity().identity })
            server.onConnection = { [weak self] conn in
                DispatchQueue.main.async { self?.acceptInbound(conn) }
            }
            try server.start()
            self.server = server
            self.client = TransferClient(identity: { try self.identity().identity })
            monitor.start()
            pollPort(attempts: 25)
            logger.log(.info, tool: "transfer", "互传服务已启动,本机指纹 \(id.fingerprint.prefix(8))…")
        } catch {
            logger.log(.error, tool: "transfer", "启动失败: \(error)")
            connectionState = .failed("启动失败: \(error.localizedDescription)")
        }
    }

    func stop() {
        monitor.stop()
        server?.stop(); server = nil
        activeConn?.cancel(); activeConn = nil
        activePairing = nil
        pendingPairingCode = nil
        connectionState = .idle
    }

    private func pollPort(attempts: Int) {
        guard attempts > 0 else { return }
        if let p = server?.port { listenPort = p; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.pollPort(attempts: attempts - 1)
        }
    }

    private func identity() throws -> DeviceIdentity.Loaded {
        if let loadedIdentity { return loadedIdentity }
        let l = try identityStore.loadOrCreate()
        loadedIdentity = l
        return l
    }

    // MARK: - 主动连接(手动 IP)

    func connect(host: String, port: UInt16, pairingCode: String?) {
        activeConn?.cancel()
        activeConn = nil
        guard let client else { return }
        connectionState = pairingCode == nil ? .connecting : .pairing
        do {
            let conn = try client.connect(host: host, port: port, pin: .acceptAny)
            self.activeConn = conn
            conn.onStateChange = { [weak self, weak conn] st in
                guard let self, let conn else { return }
                switch st {
                case .ready:
                    DispatchQueue.main.async { self.outboundReady(conn: conn, pairingCode: pairingCode) }
                case .failed(let e):
                    DispatchQueue.main.async { self.connectionState = .failed("连接失败: \(e)") }
                default:
                    break
                }
            }
        } catch {
            connectionState = .failed("连接失败: \(error.localizedDescription)")
        }
    }

    private func outboundReady(conn: TransferConnection, pairingCode: String?) {
        guard let fp = conn.peerFingerprint else { connectionState = .failed("未取到对端证书"); return }
        if pairingCode == nil {
            if let paired = peerStore.peer(forFingerprint: fp) {
                bindConnected(conn: conn, peer: paired)
            } else {
                activeConn?.cancel(); activeConn = nil
                connectionState = .failed("该设备未配对,请输入对端显示的配对码")
            }
            return
        }
        if isCoolingDown(fp) {
            activeConn?.cancel(); activeConn = nil
            connectionState = .failed("配对失败过多,请稍后再试")
            return
        }
        startPairing(conn: conn, code: pairingCode!, peerFingerprint: fp)
    }

    // MARK: - 被动接受

    private func acceptInbound(_ conn: TransferConnection) {
        conn.onStateChange = { [weak self, weak conn] st in
            guard let self, let conn else { return }
            switch st {
            case .ready:
                DispatchQueue.main.async { self.inboundReady(conn: conn) }
            case .failed(let e):
                DispatchQueue.main.async { self.connectionState = .failed("连接失败: \(e)") }
            default:
                break
            }
        }
    }

    private func inboundReady(conn: TransferConnection) {
        guard let fp = conn.peerFingerprint else { return }
        if let paired = peerStore.peer(forFingerprint: fp) {
            bindConnected(conn: conn, peer: paired)
        } else {
            if isCoolingDown(fp) { connectionState = .failed("配对失败过多,请稍后再试"); return }
            if pendingPairingCode == nil { pendingPairingCode = PairingCrypto.makeCode() }
            startPairing(conn: conn, code: pendingPairingCode!, peerFingerprint: fp)
        }
    }

    // MARK: - 配对

    private func startPairing(conn: TransferConnection, code: String, peerFingerprint fp: String) {
        connectionState = .pairing
        let selfId: DeviceIdentity.Loaded
        do { selfId = try identity() } catch { connectionState = .failed("身份加载失败"); return }
        let pm = PairingManager(code: code, selfFingerprint: selfId.fingerprint,
                                selfDeviceId: identityStore.deviceId, selfName: deviceName,
                                peerFingerprint: fp)
        pm.send = { [weak conn] msg in conn?.send(msg) }
        pm.onOutcome = { [weak self] outcome in
            DispatchQueue.main.async { self?.finishPairing(conn: conn, fp: fp, outcome: outcome) }
        }
        activePairing = pm
        // 先装 onMessage 再 begin() —— 镜像 loopback 已验证的顺序,避免漏掉对端首条消息
        conn.onMessage = { [weak pm] msg in pm?.handle(msg) }
        pm.begin()
    }

    private func finishPairing(conn: TransferConnection, fp: String, outcome: PairingManager.Outcome) {
        activePairing = nil
        switch outcome {
        case let .success(peer):
            failureCounts[fp] = 0
            peerStore.upsert(peer)
            pairedPeers = peerStore.all()
            pendingPairingCode = nil
            bindConnected(conn: conn, peer: peer)
            logger.log(.info, tool: "transfer", "已与 \(peer.name) 配对")
        case let .failed(reason):
            conn.cancel()
            if activeConn === conn { activeConn = nil }
            failureCounts[fp, default: 0] += 1
            if failureCounts[fp]! >= 3 { cooldownUntil[fp] = Date().addingTimeInterval(60) }
            pendingPairingCode = PairingCrypto.makeCode()
            connectionState = .failed(reason)
            logger.log(.warn, tool: "transfer", "配对失败: \(reason)")
        }
    }

    private func bindConnected(conn: TransferConnection, peer: PairedPeer) {
        if let old = activeConn, old !== conn { old.cancel() }
        connectionState = .connected(peerName: peer.name)
        activeConn = conn
        conn.onMessage = { [weak self] msg in
            guard case let .clipboardText(text, hash) = msg else { return }
            DispatchQueue.main.async { self?.receiveClipboard(text: text, hash: hash, peerName: peer.name) }
        }
    }

    // MARK: - 剪贴板

    private func handleLocalClipboard(text: String, hash: String) {
        guard clipboardSyncEnabled, case .connected = connectionState, let conn = activeConn else { return }
        conn.send(.clipboardText(text: text, contentHash: hash))
        appendHistory(TransferItem(kind: .text, direction: .outgoing, preview: text, peerName: currentPeerName()))
    }

    private func receiveClipboard(text: String, hash: String, peerName: String) {
        appendHistory(TransferItem(kind: .text, direction: .incoming, preview: text, peerName: peerName))
        if clipboardSyncEnabled { monitor.applyIncoming(text: text, hash: hash) }
    }

    private func appendHistory(_ item: TransferItem) {
        history.insert(item, at: 0)
        if history.count > 200 { history.removeLast() }
    }

    private func currentPeerName() -> String {
        if case let .connected(name) = connectionState { return name }
        return "对方设备"
    }

    private func isCoolingDown(_ fp: String) -> Bool {
        guard let until = cooldownUntil[fp] else { return false }
        return until > Date()
    }
}
