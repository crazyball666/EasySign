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
    private var activeIsOutbound = false             // 当前已绑定连接的方向:仅出站允许重连
    private var activePeerFingerprint: String?       // 当前已绑定对端指纹:用于拒绝陌生入站、放行同端重连
    private var activePairing: PairingManager?
    private var activePairingConn: TransferConnection?   // 强持有配对中的连接(连同其 pm),避免被并发入站顶掉
    private var failureCounts: [String: Int] = [:]
    private var cooldownUntil: [String: Date] = [:]
    private var pairFailureTimes: [Date] = []        // 全局配对失败时间戳(滑动窗口)
    private var globalPairCooldownUntil: Date?
    private var pairingCodeIssuedAt: Date?           // 当前 pendingPairingCode 的签发时间(用于 180s 过期)
    // 连接超时与尽力而为重连(仅作用于主动出站连接;入站不重连)。
    private var connectTimeoutWork: DispatchWorkItem?
    private var lastReconnect: (() -> Void)?
    private var reconnectAttempts = 0
    private var reconnectGeneration = 0
    private var userStopped = false
    private var wasConnected = false

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
        userStopped = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                _ = try self.identity()   // 首次会生成证书(慢),放后台避免卡启动
            } catch {
                DispatchQueue.main.async {
                    self.logger.log(.error, tool: "transfer", "身份加载失败: \(error)")
                    self.connectionState = .failed("身份加载失败")
                }
                return
            }
            DispatchQueue.main.async { self.startServices() }
        }
    }

    /// 在主线程启动监听/发现/剪贴板(identity 已就绪)。
    /// 单写者假设:`loadedIdentity` 由上面的后台线程在调用 startServices 之前写入一次,
    /// 此后所有访问 `identity()` 都在主线程且只读缓存,故无需加锁。
    private func startServices() {
        // 与 SettingsStore(.transferStealthMode) 共用同一 UserDefaults 裸键;
        // 此处直接读以免把 SettingsStore 注入 TransferService(默认 false = 广播开)。
        stealthMode = UserDefaults.standard.bool(forKey: "transferStealthMode")
        do {
            let id = try identity()
            // 常驻配对码:服务一启动就生成并持续显示,供想连本机的设备输入。
            // (旧设计"被连时才生成"依赖一次必然失败的无码探测连接去触发,既竞态又反直觉。)
            if pendingPairingCode == nil {
                pendingPairingCode = PairingCrypto.makeCode()
                pairingCodeIssuedAt = Date()
            }
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
        cleanupOldHistory()
    }

    func stop() {
        userStopped = true
        reconnectGeneration += 1      // 取消任何挂起的重连
        wasConnected = false
        connectTimeoutWork?.cancel(); connectTimeoutWork = nil
        monitor.stop()
        discovery.stop()
        discoveredPeers = []
        server?.stop(); server = nil
        activeConn?.cancel(); activeConn = nil
        activePeerFingerprint = nil
        fileManager.reset()
        activePairing = nil
        activePairingConn?.cancel(); activePairingConn = nil
        pendingPairingCode = nil
        pairingCodeIssuedAt = nil
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
        // 一次用户主动连接 = 取消上次的"已停止"并清零重连计数、撞代际取消任何挂起重连。
        reconnectGeneration += 1
        reconnectAttempts = 0
        userStopped = false
        wasConnected = false
        lastReconnect = { [weak self] in self?.performOutbound(host: host, port: port, pairingCode: nil) }
        performOutbound(host: host, port: port, pairingCode: pairingCode)
    }

    private func performOutbound(host: String, port: UInt16, pairingCode: String?) {
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
        reconnectGeneration += 1
        reconnectAttempts = 0
        userStopped = false
        wasConnected = false
        lastReconnect = { [weak self] in self?.performOutbound(to: peer, pairingCode: nil) }
        performOutbound(to: peer, pairingCode: pairingCode)
    }

    private func performOutbound(to peer: DiscoveredPeer, pairingCode: String?) {
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
            case .waiting(let e):
                // 网络暂时不可达(对端未就绪等)。不改状态,交给 12s 超时裁决。
                self.logger.log(.warn, tool: "transfer", "连接等待中: \(e)")
            case .failed(let e):
                DispatchQueue.main.async { self.handleOutboundDrop(conn, failure: "连接失败: \(e)") }
            case .cancelled:
                DispatchQueue.main.async { self.handleOutboundDrop(conn, failure: nil) }
            default:
                break
            }
        }
        armConnectTimeout(conn)
    }

    /// 出站连接 12s 未达 `.connected`/`.pairing`(仍 `.connecting`)则判超时取消。
    private func armConnectTimeout(_ conn: TransferConnection) {
        connectTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak conn] in
            guard let self else { return }
            if case .connecting = self.connectionState {
                conn?.cancel()
                self.connectionState = .failed("连接超时")
            } else if case .pairing = self.connectionState {
                // 配对中也设个上限
                conn?.cancel()
                self.connectionState = .failed("配对超时")
            }
        }
        connectTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    /// 出站连接断开统一处理。仅处理当前活动连接;曾建立连接(`wasConnected`)且非用户主动停止时尝试重连。
    private func handleOutboundDrop(_ conn: TransferConnection, failure: String?) {
        guard conn === activeConn else { return }   // 已被新连接取代的旧连接,忽略
        connectTimeoutWork?.cancel()
        if wasConnected && !userStopped && lastReconnect != nil {
            scheduleReconnect()
            return
        }
        if let failure { connectionState = .failed(failure) }
    }

    /// 已建立连接断开的统一收尾。清理 activeConn/状态;仅出站且非用户停止时尝试重连。
    private func handleConnectedDrop(_ conn: TransferConnection, failure: String?) {
        guard conn === activeConn else { return }   // 已被新连接取代
        connectTimeoutWork?.cancel()
        if activeIsOutbound && wasConnected && !userStopped && lastReconnect != nil {
            scheduleReconnect()
            return
        }
        // 入站(或不可重连):清理并回到空闲,避免假"已连接"+幽灵历史
        activeConn?.cancel()
        activeConn = nil
        activePeerFingerprint = nil
        fileManager.reset()
        wasConnected = false
        connectionState = failure.map { .failed($0) } ?? .idle
    }

    private func scheduleReconnect() {
        guard !userStopped, reconnectAttempts < 3, let r = lastReconnect else { return }
        wasConnected = false   // 防同一次断开的 .failed+.cancelled 双触发重连
        reconnectAttempts += 1
        let gen = reconnectGeneration
        let delay = Double(1 << reconnectAttempts) // 2,4,8
        connectionState = .failed("连接断开,重连中(\(reconnectAttempts)/3)…")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.userStopped, gen == self.reconnectGeneration else { return }
            r()
        }
    }

    private func outboundReady(conn: TransferConnection, pairingCode: String?) {
        activeIsOutbound = true   // 此连接为主动出站:断开后允许重连
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
        if isGloballyCoolingDown() {
            activeConn?.cancel(); activeConn = nil
            connectionState = .failed("配对尝试过多,请稍后再试")
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
                DispatchQueue.main.async {
                    // 仅当本连接是(或可能成为)活动会话时才改全局状态,
                    // 避免陌生入站/探测的 .failed 污染与对端 A 的现有连接。
                    if self.activeConn == nil || self.activeConn === conn {
                        self.connectionState = .failed("连接失败: \(e)")
                    }
                }
            default:
                break
            }
        }
        // 每条入站连接独立 30s 配对超时:未成为活动连接(未绑定)即断开。
        let connRef = conn
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak connRef] in
            guard let self, let connRef else { return }
            if connRef === self.activeConn { return }   // 已绑定,放过
            connRef.cancel()
        }
    }

    private func inboundReady(conn: TransferConnection) {
        guard let fp = conn.peerFingerprint else { return }
        if case .connected = connectionState, let ac = activeConn, ac !== conn {
            if fp != activePeerFingerprint {   // 已与他人连接,拒绝陌生入站,避免污染当前会话
                conn.cancel(); return
            }
            // 同一对端重连:继续往下走(会在 bindConnected 里替换旧连接)
        }
        activeIsOutbound = false   // 此连接为被动入站:断开后不重连
        if let paired = peerStore.peer(forFingerprint: fp) {
            bindConnected(conn: conn, peer: paired)
        } else {
            // 全局限速:静默取消,不向攻击者暴露(避免每换证书绕过 per-fp 冷却)。
            if isGloballyCoolingDown() {
                logger.log(.warn, tool: "transfer", "配对尝试过多,已临时拒绝入站配对请求")
                conn.cancel(); return
            }
            if isCoolingDown(fp) { conn.cancel(); return }   // 静默取消,与全局冷却一致
            // 常驻配对码:启动时已生成并持续显示给对端读取,此处不轮换,
            // 否则对端正照着屏幕输入时码却变了,必然配对失败。仅作 nil 兜底。
            if pendingPairingCode == nil { pendingPairingCode = PairingCrypto.makeCode(); pairingCodeIssuedAt = Date() }
            startPairing(conn: conn, code: pendingPairingCode!, peerFingerprint: fp)
        }
    }

    // MARK: - 配对

    private func startPairing(conn: TransferConnection, code: String, peerFingerprint fp: String) {
        // 并发入站:若已有另一条连接正在配对,顶替(supersede)旧的,避免旧连接被孤立永不收尾。
        if let oldConn = activePairingConn, oldConn !== conn {
            oldConn.cancel()
        }
        activePairing = nil
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
        activePairingConn = conn   // 强持有,保证配对期间 pm/conn 不被并发入站释放
        // 先装 onMessage 再 begin() —— 镜像 loopback 已验证的顺序,避免漏掉对端首条消息。
        // 强捕获 pm:连接持有该闭包即维持 pm 存活;pm.send 为 [weak conn]、onOutcome 为 [weak self],无循环引用。
        conn.onMessage = { msg in pm.handle(msg) }
        pm.begin()
    }

    private func finishPairing(conn: TransferConnection, fp: String, outcome: PairingManager.Outcome) {
        activePairing = nil
        activePairingConn = nil    // 释放配对期的强持有;成功时由 bindConnected 接管 activeConn
        switch outcome {
        case let .success(peer):
            failureCounts[fp] = 0
            peerStore.upsert(peer)
            pairedPeers = peerStore.all()
            // 配对成功后轮换出新码:旧码即时失效(防重放),同时常驻显示不留空。
            pendingPairingCode = PairingCrypto.makeCode()
            pairingCodeIssuedAt = Date()
            bindConnected(conn: conn, peer: peer)
            logger.log(.info, tool: "transfer", "已与 \(peer.name) 配对")
        case let .failed(reason):
            conn.cancel()
            if activeConn === conn { activeConn = nil }
            failureCounts[fp, default: 0] += 1
            if failureCounts[fp]! >= 3 { cooldownUntil[fp] = Date().addingTimeInterval(60) }
            recordPairFailure()    // 全局(与指纹无关)滑动窗口限速
            pendingPairingCode = PairingCrypto.makeCode()
            pairingCodeIssuedAt = Date()
            connectionState = .failed(reason)
            logger.log(.warn, tool: "transfer", "配对失败: \(reason)")
        }
    }

    private func bindConnected(conn: TransferConnection, peer: PairedPeer) {
        connectTimeoutWork?.cancel()
        reconnectAttempts = 0
        wasConnected = true
        if let old = activeConn, old !== conn { old.cancel() }
        connectionState = .connected(peerName: peer.name)
        activeConn = conn
        activePeerFingerprint = peer.fingerprint
        // 绑定后统一接管断开收尾(覆盖 acceptInbound/beginOutbound 的 pre-bind 回调),
        // 入站/出站均处理:出站 .cancelled 也曾被忽略,入站 .cancelled 之前完全没有收尾。
        conn.onStateChange = { [weak self, weak conn] st in
            guard let self, let conn else { return }
            switch st {
            case .failed(let e):
                DispatchQueue.main.async { self.handleConnectedDrop(conn, failure: "连接断开: \(e)") }
            case .cancelled:
                DispatchQueue.main.async { self.handleConnectedDrop(conn, failure: nil) }
            default:
                break
            }
        }
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
            sendBinary: { [weak conn] data, done in
                if let c = conn { c.sendBinary(data, completion: done) } else { done() }
            },
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
            sendBinary: { [weak conn] data, done in
                if let c = conn { c.sendBinary(data, completion: done) } else { done() }
            },
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
        if history.count > 200 {
            let dropped = history.removeLast()
            if let url = dropped.localURL { try? FileManager.default.removeItem(at: url) }
        }
        historyStore.save(history)
    }

    private func currentPeerName() -> String {
        if case let .connected(name) = connectionState { return name }
        return "对方设备"
    }

    // MARK: - 清理 / 清空

    /// 启动时按保留天数清理历史与 inbox 文件(0 = 永久保留,不清理)。
    private func cleanupOldHistory() {
        let days = UserDefaults.standard.integer(forKey: "transferRetentionDays")
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        // prune history
        let kept = historyStore.pruning(history, olderThan: cutoff)
        if kept.count != history.count {
            history = kept; historyStore.save(history)
        }
        // delete inbox files older than cutoff
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: TransferPaths.inbox, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for f in files {
                if let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, d < cutoff {
                    try? fm.removeItem(at: f)
                }
            }
        }
    }

    func clearHistory() {
        history = []; historyStore.clear()
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: TransferPaths.inbox, includingPropertiesForKeys: nil) {
            for f in files { try? fm.removeItem(at: f) }
        }
    }

    func clearPairedDevices() { peerStore.removeAll(); pairedPeers = [] }

    private func isCoolingDown(_ fp: String) -> Bool {
        guard let until = cooldownUntil[fp] else { return false }
        return until > Date()
    }

    /// 全局(与对端指纹无关)配对冷却:防止攻击者每次换自签证书绕过 per-fp 限速。
    private func isGloballyCoolingDown() -> Bool {
        if let until = globalPairCooldownUntil, until > Date() { return true }
        return false
    }

    /// 记录一次配对失败(全局滑动窗口);60s 内累计 5 次触发 60s 全局冷却。
    private func recordPairFailure() {
        let now = Date()
        pairFailureTimes.append(now)
        pairFailureTimes = pairFailureTimes.filter { now.timeIntervalSince($0) < 60 }   // 60s 窗口
        if pairFailureTimes.count >= 5 {
            globalPairCooldownUntil = now.addingTimeInterval(60)  // 触发 60s 全局冷却
            pairFailureTimes.removeAll()
        }
    }
}
