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
    @Published var discoveredPeers: [DiscoveredPeer] = []
    @Published var activeTransfers: [FileTransferManager.Progress] = []

    private let identityStore = DeviceIdentityStore()
    private let peerStore = PairedPeerStore()
    private let monitor = ClipboardMonitor()
    private let fileManager = FileTransferManager()
    private let historyStore = TransferHistoryStore()
    private lazy var discovery = PeerDiscovery(selfDeviceId: { [weak self] in self?.identityStore.deviceId ?? "" })
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
        self.history = historyStore.load()
        monitor.onLocalText = { [weak self] text, hash in
            DispatchQueue.main.async { self?.handleLocalClipboard(text: text, hash: hash) }
        }
        monitor.onLocalImage = { [weak self] data, hash in
            DispatchQueue.main.async { self?.handleLocalImage(data: data, hash: hash) }
        }
        fileManager.onProgress = { [weak self] p in
            DispatchQueue.main.async { self?.updateProgress(p) }
        }
        fileManager.onReceived = { [weak self] _, name, url, isImage in
            DispatchQueue.main.async {
                guard let self else { return }
                if isImage {
                    // 图片:仅在剪贴板同步开启时写入剪贴板(与文本一致);文件保留在 inbox 供历史打开。
                    if self.clipboardSyncEnabled, let png = try? Data(contentsOf: url) {
                        self.monitor.applyIncomingImage(pngData: png, hash: ClipboardCodec.hash(data: png))
                    }
                    self.appendHistory(TransferItem(kind: .image, direction: .incoming,
                                                    preview: "图片", peerName: self.currentPeerName(),
                                                    localURL: url))
                } else {
                    self.appendHistory(TransferItem(kind: .file, direction: .incoming,
                                                    preview: name, peerName: self.currentPeerName(),
                                                    localURL: url))
                }
            }
        }
    }

    /// 进度上移(主线程):按 id upsert;收/发齐(bytes>=total)后短暂保留再移除。
    private func updateProgress(_ p: FileTransferManager.Progress) {
        if let idx = activeTransfers.firstIndex(where: { $0.id == p.id }) {
            activeTransfers[idx] = p
        } else {
            activeTransfers.append(p)
        }
        if p.total > 0 && p.bytes >= p.total {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.activeTransfers.removeAll { $0.id == p.id }
            }
        }
    }

    var deviceName: String { identityStore.deviceName }

    /// 隐身模式:不对外广播 Bonjour(仍可被手动 IP 连接)。
    /// 注:start() 初值直接读 UserDefaults 同一裸键(见下),避免把 SettingsStore 注入本类。
    private var stealthMode = false

    /// 修改设备名并(若已在广播)用新名字重建 TXT 重新广播。
    func setDeviceName(_ name: String) {
        identityStore.deviceName = name
        // 重新广播以更新 TXT 中的 name(若已在广播)
        server?.advertiseInfo = (deviceId: identityStore.deviceId, name: name, fingerprint: loadedIdentity?.fingerprint ?? "")
        server?.setAdvertising(!stealthMode)
    }

    /// 开关隐身模式。由设置页调用,立即作用于现有 listener 的广播。
    func setStealthMode(_ on: Bool) {
        stealthMode = on
        server?.setAdvertising(!on)
    }

    // MARK: - 生命周期

    func start() {
        // 与 SettingsStore(.transferStealthMode) 共用同一 UserDefaults 裸键;
        // 此处直接读以免把 SettingsStore 注入 TransferService(默认 false = 广播开)。
        stealthMode = UserDefaults.standard.bool(forKey: "transferStealthMode")
        do {
            let id = try identity()
            let server = TransferServer(identity: { try self.identity().identity })
            server.onConnection = { [weak self] conn in
                DispatchQueue.main.async { self?.acceptInbound(conn) }
            }
            // 在 start() 前装好广播信息(deviceId/name/指纹),随监听一起对外广播。
            server.advertiseInfo = (deviceId: identityStore.deviceId, name: deviceName, fingerprint: id.fingerprint)
            try server.start()
            server.setAdvertising(!stealthMode)
            self.server = server
            self.client = TransferClient(identity: { try self.identity().identity })
            // 启动 Bonjour 浏览,发现局域网内其它 EasySign 设备。
            discovery.onPeersChanged = { [weak self] peers in
                DispatchQueue.main.async { self?.discoveredPeers = peers }
            }
            discovery.start()
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
        discovery.stop()
        discoveredPeers = []
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
            beginOutbound(conn, pairingCode: pairingCode)
        } catch {
            connectionState = .failed("连接失败: \(error.localizedDescription)")
        }
    }

    /// 连接 Bonjour 发现出的对端。复用与手动 IP 完全相同的配对/pinning 流程(`.acceptAny` → 读指纹 → 配对/绑定)。
    func connect(to peer: DiscoveredPeer, pairingCode: String?) {
        activeConn?.cancel()
        activeConn = nil
        guard let client else { return }
        connectionState = pairingCode == nil ? .connecting : .pairing
        do {
            let conn = try client.connect(endpoint: peer.endpoint, pin: .acceptAny)
            beginOutbound(conn, pairingCode: pairingCode)
        } catch {
            connectionState = .failed("连接失败: \(error.localizedDescription)")
        }
    }

    /// 主动连接(host/port 与 endpoint)共用的 post-`.ready` 装配:安装状态回调并记录 activeConn。
    private func beginOutbound(_ conn: TransferConnection, pairingCode: String?) {
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
        conn.onBinary = { [weak self] data in self?.fileManager.handleBinary(data) }
        conn.onMessage = { [weak self] msg in
            guard let self else { return }
            switch msg {
            case let .clipboardText(text, hash):
                DispatchQueue.main.async { self.receiveClipboard(text: text, hash: hash, peerName: peer.name) }
            case let .fileOffer(id, name, size):
                self.fileManager.handleOffer(id: id, name: name, size: size, isImage: false)
            case let .clipboardImageOffer(id, size, _):
                self.fileManager.handleOffer(id: id, name: "image-\(id).png", size: size, isImage: true)
            case let .fileComplete(id):
                self.fileManager.handleComplete(id: id)
            default:
                break
            }
        }
    }

    /// 发送一个本地文件给当前已连接对端(分块二进制帧,流式读盘)。
    func sendFile(_ url: URL) {
        guard case .connected = connectionState, let conn = activeConn else { return }
        let id = UUID().uuidString
        let name = url.lastPathComponent
        fileManager.send(id: id, name: name, fileURL: url, isImage: false,
            offer: { [weak conn] id, name, size in conn?.send(.fileOffer(id: id, name: name, size: size)) },
            sendBinary: { [weak conn] data in conn?.sendBinary(data) },
            complete: { [weak conn] id in conn?.send(.fileComplete(id: id)) },
            done: { [weak self] in DispatchQueue.main.async {
                self?.appendHistory(TransferItem(kind: .file, direction: .outgoing,
                                                 preview: name, peerName: self?.currentPeerName() ?? "对方设备"))
            } })
    }

    // MARK: - 剪贴板

    private func handleLocalClipboard(text: String, hash: String) {
        guard clipboardSyncEnabled, case .connected = connectionState, let conn = activeConn else { return }
        conn.send(.clipboardText(text: text, contentHash: hash))
        appendHistory(TransferItem(kind: .text, direction: .outgoing, preview: text, peerName: currentPeerName()))
    }

    private func handleLocalImage(data: Data, hash: String) {
        guard clipboardSyncEnabled, case .connected = connectionState, let conn = activeConn else { return }
        let id = UUID().uuidString
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("eztx-\(id).png")
        guard (try? data.write(to: tmp)) != nil else { return }
        fileManager.send(id: id, name: "image.png", fileURL: tmp, isImage: true,
            offer: { [weak conn] id, _, size in conn?.send(.clipboardImageOffer(id: id, size: size, hash: hash)) },
            sendBinary: { [weak conn] d in conn?.sendBinary(d) },
            complete: { [weak conn] id in conn?.send(.fileComplete(id: id)) },
            done: { [weak self] in
                try? FileManager.default.removeItem(at: tmp)
                DispatchQueue.main.async {
                    self?.appendHistory(TransferItem(kind: .image, direction: .outgoing, preview: "图片", peerName: self?.currentPeerName() ?? "对方设备"))
                }
            })
    }

    private func receiveClipboard(text: String, hash: String, peerName: String) {
        appendHistory(TransferItem(kind: .text, direction: .incoming, preview: text, peerName: peerName))
        if clipboardSyncEnabled { monitor.applyIncoming(text: text, hash: hash) }
    }

    private func appendHistory(_ item: TransferItem) {
        history.insert(item, at: 0)
        if history.count > 200 { history.removeLast() }
        historyStore.save(history)
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
