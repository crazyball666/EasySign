import Foundation
import Network
import Security
import AppKit

/// TransferNetworkMonitor 的 callback 在其私有队列执行且为 @Sendable。
/// bridge 自身只有一个初始化后不变的 weak 引用，并且只在 main queue 解引用服务，
/// 因而无需把整个 TransferService 错标为 Sendable。
private final class TransferServiceNetworkPathBridge: @unchecked Sendable {
    weak var service: TransferService?
    private let lock = NSLock()
    private var generation: UInt = 0
    private var active = false

    func activate() {
        lock.lock()
        generation &+= 1
        active = true
        lock.unlock()
    }

    func deactivate() {
        lock.lock()
        generation &+= 1
        active = false
        lock.unlock()
    }

    func deliver(_ isSatisfied: Bool, transition: TransferNetworkTransition) {
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        let deliveryGeneration = generation
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let isCurrent = self.active && self.generation == deliveryGeneration
            self.lock.unlock()
            guard isCurrent else { return }
            self.service?.handleNetworkPath(isSatisfied, transition: transition)
        }
    }
}

/// `.bye` send completion 与 0.5s fallback 可能从不同队列到达；锁保证只关闭一次。
private final class TransferConnectionCloseOnce: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: TransferConnection
    private var closed = false

    init(_ connection: TransferConnection) {
        self.connection = connection
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        connection.cancel()
    }
}

/// 互传服务门面。串联身份 / 监听 / 连接 / 剪贴板 / 配对,持有 @Published 状态供 UI 观察。
/// 设计要点:剪贴板同步、收消息不依赖主窗口(本对象活在 ServiceHub,App 生命周期)。
final class TransferService: ObservableObject {
    private struct ActiveOutboundAttempt {
        let id: UUID
        let origin: TransferConnectionOrigin
    }

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
    private var activePeerFingerprint: String?       // 当前已绑定对端指纹:用于拒绝陌生入站、放行同端重连
    private var activePairing: PairingManager?
    private var activePairingConn: TransferConnection?   // 强持有配对中的连接(连同其 pm),避免被并发入站顶掉
    private var failureCounts: [String: Int] = [:]
    private var cooldownUntil: [String: Date] = [:]
    private var pairFailureTimes: [Date] = []        // 全局配对失败时间戳(滑动窗口)
    private var globalPairCooldownUntil: Date?
    private var pairingCodeIssuedAt: Date?           // 当前 pendingPairingCode 的签发时间(用于 180s 过期)
    // 出站连接超时、自动恢复与显式 Retry。
    private var connectTimeoutWork: DispatchWorkItem?
    private var cleanupTimer: DispatchSourceTimer?   // 定时按保留天数回收历史/inbox 文件
    private var lastManualConnect: (() -> Void)?     // 仅供 UI 显式「重试」，自动恢复绝不读取
    private var stopRequested = false
    private var lastConnectedPeer: TransferAutoReconnect.PeerRef?
    private var networkPathSatisfied: Bool?
    private var reconnectCoordinator = TransferReconnectCoordinator()
    private var reconnectWork: DispatchWorkItem?
    private var reconnectScheduledToken: TransferReconnectCoordinator.Token?
    private var activeOutboundAttempt: ActiveOutboundAttempt?
    private var manualRetryRequest: TransferManualRetryRequest?
    private var lastBonjourRepairAt: TimeInterval?
    private var serviceGeneration = TransferReconnectExecutionPolicy.ServiceGeneration()
    private var servicesRunning: Bool { serviceGeneration.isRunning }
    private let networkPathBridge = TransferServiceNetworkPathBridge()
    private lazy var networkMonitor = TransferNetworkMonitor { [networkPathBridge] isSatisfied, transition in
        networkPathBridge.deliver(isSatisfied, transition: transition)
    }
    private var appActiveObserver: NSObjectProtocol?  // NSApplication.didBecomeActive
    private var didWakeObserver: NSObjectProtocol?    // NSWorkspace.didWake(系统睡醒)

    init(logger: LoggerService) {
        self.logger = logger
        networkPathBridge.service = self
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
        server?.setAdvertiseInfo((deviceId: identityStore.deviceId, name: name, fingerprint: loadedIdentity?.fingerprint ?? ""))
        server?.setAdvertising(!stealthMode)
    }

    /// 开关隐身模式。由设置页调用,立即作用于现有 listener 的广播。
    func setStealthMode(_ on: Bool) {
        stealthMode = on
        server?.setAdvertising(!on)
    }

    // MARK: - 生命周期

    func start() {
        stopRequested = false
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
    /// 单写者假设:`loadedIdentity` 由上面的后台线程在调用 startServices 之前写入一次,此后只读不再改。
    /// 故后续 `identity()` 即便被 server 的 `{ try self.identity().identity }` 闭包在 transfer.server 队列上
    /// (listener 自愈/重建时)调用,也只是读取这份「初始化后即不变」的缓存引用,无写竞态,无需加锁。
    private func startServices() {
        guard !stopRequested, !servicesRunning else { return }
        let generation = serviceGeneration.begin()
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
                DispatchQueue.main.async {
                    self?.acceptInbound(conn, generation: generation)
                }
            }
            // listener 重建(.failed 自愈 / 睡醒)会换端口:.ready 时把新端口同步到 @Published 显示;
            // 掉线置 nil,避免「本机」卡片继续展示一个已失效的端口。
            server.onStateChange = { [weak self] st, port in
                DispatchQueue.main.async {
                    guard let self,
                          self.serviceGeneration.accepts(generation) else { return }
                    switch st {
                    case .ready:                 self.listenPort = port
                    case .failed, .cancelled:    self.listenPort = nil
                    default:                     break
                    }
                }
            }
            // 在 start() 前装好广播信息(deviceId/name/指纹),随监听一起对外广播。
            server.setAdvertiseInfo((deviceId: identityStore.deviceId, name: deviceName, fingerprint: id.fingerprint))
            try server.start()
            server.setAdvertising(!stealthMode)
            self.server = server
            self.client = TransferClient(identity: { try self.identity().identity })
            // PeerDiscovery 的 production bridge 已保证 callback 按 FIFO 在 main queue 执行。
            discovery.onPeersChanged = { [weak self] peers in
                self?.handleDiscoveredPeers(peers)
            }
            discovery.onFailure = { [weak self] error in
                self?.handleDiscoveryFailure(error)
            }
            guard serviceGeneration.activate(generation) else {
                server.stop()
                return
            }
            discovery.start()
            installLifecycleObservers()
            monitor.start()
            networkPathBridge.activate()
            networkMonitor.start()
            // 监听端口由 server.onStateChange 的 .ready 同步到 listenPort(见上),无需再轮询 server.port(跨线程读)。
            logger.log(.info, tool: "transfer", "互传服务已启动,本机指纹 \(id.fingerprint.prefix(8))…")
        } catch {
            serviceGeneration.stop()
            logger.log(.error, tool: "transfer", "启动失败: \(error)")
            connectionState = .failed("启动失败: \(error.localizedDescription)")
        }
        cleanupOldHistory()
        startCleanupTimer()
    }

    func stop() {
        stopRequested = true
        executeLifecycleActions(
            TransferReconnectExecutionPolicy.lifecycleActions(
                for: .stop,
                hasBoundConnection: hasBoundConnection
            )
        )
    }

    /// 断开当前连接但不停服务、不解除配对:回到"未连接",对端仍在已配对列表,可一键重连。
    /// 与 stop() 不同——监听/发现/剪贴板继续运行,本机仍可被发现、可主动或被动重新连接。
    func disconnect() {
        executeLifecycleActions(
            TransferReconnectExecutionPolicy.lifecycleActions(
                for: .disconnect,
                hasBoundConnection: hasBoundConnection
            )
        )
        logger.log(.info, tool: "transfer", "已手动断开当前连接(配对关系保留)")
    }

    private func identity() throws -> DeviceIdentity.Loaded {
        if let loadedIdentity { return loadedIdentity }
        let l = try identityStore.loadOrCreate()
        loadedIdentity = l
        return l
    }

    // MARK: - 主动连接(手动 IP)

    func connect(host: String, port: UInt16, pairingCode: String?) {
        manualRetryRequest = TransferManualRetryRequest(
            target: .host(host: host, port: port),
            pairingCode: pairingCode
        )
        installManualRetryAction()
        prepareExplicitConnection(to: nil)
        performOutbound(
            host: host,
            port: port,
            pairingCode: pairingCode,
            origin: .user
        )
    }

    /// UI「重试」只重放显式用户请求；peer endpoint 每次从最新 Bonjour snapshot 解析。
    func retry() { lastManualConnect?() }
    var canRetry: Bool { manualRetryRequest != nil }

    /// 用户点击 Bonjour peer 的显式连接入口。
    func connect(to peer: DiscoveredPeer, pairingCode: String?) {
        let peerRef = TransferAutoReconnect.PeerRef(
            deviceId: peer.deviceId,
            fingerprint: peer.fingerprint
        )
        manualRetryRequest = TransferManualRetryRequest(
            target: .peer(peerRef),
            pairingCode: pairingCode
        )
        installManualRetryAction()
        prepareExplicitConnection(to: pairedPeerRef(forFingerprint: peer.fingerprint))
        performOutbound(to: peer, pairingCode: pairingCode, origin: .user)
    }

    private func installManualRetryAction() {
        lastManualConnect = { [weak self] in
            self?.performManualRetry()
        }
    }

    private func performManualRetry() {
        guard let request = manualRetryRequest else { return }
        switch request.target {
        case let .host(host, port):
            prepareExplicitConnection(to: nil)
            performOutbound(
                host: host,
                port: port,
                pairingCode: request.pairingCode,
                origin: .user
            )
        case let .peer(peerRef):
            prepareExplicitConnection(to: pairedPeerRef(forFingerprint: peerRef.fingerprint))
            guard let peer = TransferManualRetryPolicy.resolvePeer(
                request,
                discovered: discoveredPeers
            ) else {
                connectionState = .failed("等待设备重新出现后再重试")
                return
            }
            performOutbound(to: peer, pairingCode: request.pairingCode, origin: .user)
        }
    }

    private func prepareExplicitConnection(to peer: TransferAutoReconnect.PeerRef?) {
        cancelReconnectScheduling()
        reconnectCoordinator.cancelAutomaticRecovery()
        if let peer {
            reconnectCoordinator.explicitlyConnecting(to: peer)
        }
        cleanupUnboundAutomaticAttempt()
    }

    private func pairedPeerRef(forFingerprint fingerprint: String) -> TransferAutoReconnect.PeerRef? {
        guard let paired = peerStore.peer(forFingerprint: fingerprint) else { return nil }
        return .init(deviceId: paired.deviceId, fingerprint: paired.fingerprint)
    }

    private func prepareForNewOutboundConnection() {
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
        activeOutboundAttempt = nil
        activePairing = nil
        if let pairingConn = activePairingConn {
            activePairingConn = nil
            if pairingConn !== activeConn { pairingConn.cancel() }
        }
        if let connection = activeConn {
            activeConn = nil
            connection.cancel()
        }
        activePeerFingerprint = nil
        fileManager.reset()
    }

    private func performOutbound(
        host: String,
        port: UInt16,
        pairingCode requestedCode: String?,
        origin: TransferConnectionOrigin
    ) {
        prepareForNewOutboundConnection()
        let attemptID = UUID()
        activeOutboundAttempt = ActiveOutboundAttempt(id: attemptID, origin: origin)
        let pairingCode = origin.pairingCode(requested: requestedCode)
        connectionState = pairingCode == nil ? .connecting : .pairing
        logger.log(.info, tool: "transfer", "发起出站连接 → \(host):\(port)(\(pairingCode == nil ? "无码/重连" : "配对码"))")

        guard let client else {
            finishOutboundAttempt(
                id: attemptID,
                conn: nil,
                origin: origin,
                failure: "连接服务尚未就绪"
            )
            return
        }
        do {
            let pin = origin.expectedFingerprint.map {
                TransferTLS.PinMode.requirePinned(fingerprint: $0)
            } ?? .acceptAny
            let conn = try client.connect(host: host, port: port, pin: pin)
            beginOutbound(
                conn,
                attemptID: attemptID,
                pairingCode: pairingCode,
                origin: origin
            )
        } catch {
            logger.log(.error, tool: "transfer", "出站连接创建失败: \(error.localizedDescription)")
            finishOutboundAttempt(
                id: attemptID,
                conn: nil,
                origin: origin,
                failure: "连接失败: \(error.localizedDescription)"
            )
        }
    }

    private func performOutbound(
        to peer: DiscoveredPeer,
        pairingCode requestedCode: String?,
        origin: TransferConnectionOrigin
    ) {
        prepareForNewOutboundConnection()
        let attemptID = UUID()
        activeOutboundAttempt = ActiveOutboundAttempt(id: attemptID, origin: origin)
        let pairingCode = origin.pairingCode(requested: requestedCode)
        connectionState = pairingCode == nil ? .connecting : .pairing
        logger.log(.info, tool: "transfer", "发起出站连接(Bonjour)→ \(String(describing: peer.endpoint))(\(pairingCode == nil ? "无码/重连" : "配对码"))")

        guard let client else {
            finishOutboundAttempt(
                id: attemptID,
                conn: nil,
                origin: origin,
                failure: "连接服务尚未就绪"
            )
            return
        }
        do {
            let pin = origin.expectedFingerprint.map {
                TransferTLS.PinMode.requirePinned(fingerprint: $0)
            } ?? .acceptAny
            let conn = try client.connect(endpoint: peer.endpoint, pin: pin)
            beginOutbound(
                conn,
                attemptID: attemptID,
                pairingCode: pairingCode,
                origin: origin
            )
        } catch {
            logger.log(.error, tool: "transfer", "出站连接创建失败: \(error.localizedDescription)")
            finishOutboundAttempt(
                id: attemptID,
                conn: nil,
                origin: origin,
                failure: "连接失败: \(error.localizedDescription)"
            )
        }
    }

    private func beginOutbound(
        _ conn: TransferConnection,
        attemptID: UUID,
        pairingCode: String?,
        origin: TransferConnectionOrigin
    ) {
        guard activeOutboundAttempt?.id == attemptID else {
            conn.cancel()
            return
        }
        activeConn = conn
        conn.onStateChange = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .ready:
                self.logger.log(.info, tool: "transfer", "出站:握手完成 .ready,读取对端指纹…")
                DispatchQueue.main.async {
                    self.outboundReady(
                        conn: conn,
                        attemptID: attemptID,
                        pairingCode: pairingCode,
                        origin: origin
                    )
                }
            case let .waiting(error):
                self.logger.log(.warn, tool: "transfer", "出站:连接等待中: \(error)")
            case let .failed(error):
                self.logger.log(.warn, tool: "transfer", "出站:连接失败 \(error)")
                DispatchQueue.main.async {
                    self.finishOutboundAttempt(
                        id: attemptID,
                        conn: conn,
                        origin: origin,
                        failure: "连接失败: \(error)"
                    )
                }
            case .cancelled:
                DispatchQueue.main.async {
                    self.finishOutboundAttempt(
                        id: attemptID,
                        conn: conn,
                        origin: origin,
                        failure: nil
                    )
                }
            default:
                self.logger.log(.info, tool: "transfer", "出站连接状态: \(Self.describe(state))")
            }
        }
        armConnectTimeout(
            conn,
            attemptID: attemptID,
            origin: origin
        )
    }

    private static func describe(_ state: NWConnection.State) -> String {
        switch state {
        case .setup:            return "setup"
        case let .waiting(e):   return "waiting(\(e))"
        case .preparing:        return "preparing(TLS/WebSocket 握手中)"
        case .ready:            return "ready"
        case let .failed(e):    return "failed(\(e))"
        case .cancelled:        return "cancelled"
        @unknown default:       return "unknown"
        }
    }

    private func armConnectTimeout(
        _ conn: TransferConnection,
        attemptID: UUID,
        origin: TransferConnectionOrigin
    ) {
        connectTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak conn] in
            guard let self else { return }
            let failure: String
            if case .pairing = self.connectionState {
                failure = "配对超时"
            } else {
                failure = "连接超时(握手未完成,可能是网络/VPN/MTU 问题)"
            }
            self.logger.log(.warn, tool: "transfer", "出站:12s 内未绑定，收口 attempt \(attemptID)")
            self.finishOutboundAttempt(
                id: attemptID,
                conn: conn,
                origin: origin,
                failure: failure
            )
        }
        connectTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    private func outboundReady(
        conn: TransferConnection,
        attemptID: UUID,
        pairingCode: String?,
        origin: TransferConnectionOrigin
    ) {
        guard activeOutboundAttempt?.id == attemptID,
              conn === activeConn else { return }
        guard let fp = conn.peerFingerprint else {
            logger.log(.warn, tool: "transfer", "出站:.ready 但读不到对端证书指纹")
            finishOutboundAttempt(
                id: attemptID,
                conn: conn,
                origin: origin,
                failure: "未取到对端证书"
            )
            return
        }
        logger.log(.info, tool: "transfer", "出站:已读到对端指纹 \(fp.prefix(8))…(\(pairingCode == nil ? "查已配对" : "开始配对"))")

        if case let .automatic(token) = origin {
            guard let paired = peerStore.peer(forFingerprint: fp),
                  TransferReconnectExecutionPolicy.readyPeerMatches(
                      token: token,
                      actual: paired
                  ) else {
                finishOutboundAttempt(
                    id: attemptID,
                    conn: conn,
                    origin: origin,
                    failure: "自动重连对端身份不匹配"
                )
                return
            }
            bindConnected(
                conn: conn,
                peer: paired,
                outboundAttempt: ActiveOutboundAttempt(id: attemptID, origin: origin)
            )
            return
        }

        let paired = peerStore.peer(forFingerprint: fp)
        if let paired {
            reconnectCoordinator.explicitlyConnecting(to: .init(
                deviceId: paired.deviceId,
                fingerprint: paired.fingerprint
            ))
        }

        if pairingCode == nil {
            if let paired {
                bindConnected(
                    conn: conn,
                    peer: paired,
                    outboundAttempt: ActiveOutboundAttempt(id: attemptID, origin: origin)
                )
            } else {
                finishOutboundAttempt(
                    id: attemptID,
                    conn: conn,
                    origin: origin,
                    failure: "该设备未配对,请输入对端显示的配对码"
                )
            }
            return
        }
        if isGloballyCoolingDown() {
            finishOutboundAttempt(
                id: attemptID,
                conn: conn,
                origin: origin,
                failure: "配对尝试过多,请稍后再试"
            )
            return
        }
        if isCoolingDown(fp) {
            finishOutboundAttempt(
                id: attemptID,
                conn: conn,
                origin: origin,
                failure: "配对失败过多,请稍后再试"
            )
            return
        }
        logger.log(.info, tool: "transfer", "发起配对,对端 \(fp.prefix(8))…,输入码 \(pairingCode!)")
        startPairing(
            conn: conn,
            code: pairingCode!,
            peerFingerprint: fp,
            outboundAttempt: ActiveOutboundAttempt(id: attemptID, origin: origin)
        )
    }

    private func finishOutboundAttempt(
        id: UUID,
        conn: TransferConnection?,
        origin: TransferConnectionOrigin,
        failure: String?
    ) {
        let attemptMatches = activeOutboundAttempt?.id == id
            && activeOutboundAttempt?.origin == origin
        let connectionMatches = conn.map { $0 === activeConn } ?? true
        let tokenAccepted: Bool
        if case let .automatic(token) = origin {
            tokenAccepted = reconnectCoordinator.accepts(token)
        } else {
            tokenAccepted = false
        }

        let decision = TransferReconnectExecutionPolicy.completionDecision(
            attemptMatches: attemptMatches,
            connectionMatches: connectionMatches,
            tokenAccepted: tokenAccepted
        )
        guard decision != .ignore else { return }

        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
        activeOutboundAttempt = nil
        let clearsPairing = conn.map { activePairingConn === $0 } ?? false
        if let conn {
            if activeConn === conn { activeConn = nil }
            if activePairingConn === conn { activePairingConn = nil }
            conn.cancel()
        }
        if clearsPairing { activePairing = nil }
        activePeerFingerprint = nil
        fileManager.reset()

        switch origin {
        case .user:
            let message: String
            if let failure {
                message = failure
            } else if case .pairing = connectionState {
                message = "配对未完成:对端未响应(检查配对码或稍后重试)"
            } else {
                message = "连接已断开"
            }
            connectionState = .failed(message)
        case let .automatic(token):
            switch decision {
            case .ignore:
                break
            case .cleanupOnly:
                showWaitingForRecovery(failure)
            case .cleanupAndRetry:
                if let failure {
                    logger.log(.info, tool: "transfer", "自动重连 attempt 失败: \(failure)")
                }
                executeReconnect(reconnectCoordinator.attemptFailed(token))
            }
        }
        resumeDeferredAutomaticRecoveryIfPossible()
    }

    // MARK: - 被动接受

    private func acceptInbound(
        _ conn: TransferConnection,
        generation: UInt
    ) {
        guard serviceGeneration.accepts(generation) else {
            conn.cancel()
            return
        }
        let lifecycle = TransferReconnectExecutionPolicy.InboundConnectionLifecycle(
            connection: conn
        )
        logger.log(.info, tool: "transfer", "① 收到入站连接,等待握手 .ready…")
        conn.onStateChange = { [weak self, weak conn] st in
            guard let self, let conn else { return }
            switch st {
            case .ready:
                self.logger.log(.info, tool: "transfer", "② 入站连接已 .ready,转入 inboundReady")
                DispatchQueue.main.async {
                    self.inboundReady(
                        conn: conn,
                        lifecycle: lifecycle,
                        generation: generation
                    )
                }
            case .failed(let e):
                DispatchQueue.main.async {
                    self.finishUnboundInboundConnection(
                        conn,
                        lifecycle: lifecycle,
                        generation: generation,
                        event: .failed,
                        failure: "连接失败: \(e)"
                    )
                }
            case .cancelled:
                DispatchQueue.main.async {
                    self.finishUnboundInboundConnection(
                        conn,
                        lifecycle: lifecycle,
                        generation: generation,
                        event: .cancelled,
                        failure: "入站配对连接已关闭"
                    )
                }
            default:
                break
            }
        }
        // 关键修复:强持有这条入站连接到 30s(覆盖握手 + 配对窗口)。否则 acceptInbound 一返回
        // 就无人强引用 conn —— 跨机网络延迟下,握手还没完成 conn 就被释放,.ready 落到已死的
        // wrapper(stateUpdateHandler 的 [weak self] 为 nil)→ inboundReady 永远不触发(本机环回
        // 握手极快才侥幸不复现)。绑定后由 activeConn 接管;到点仍未绑定则取消、随闭包一起释放。
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self else { return }
            if conn === self.activeConn { return }   // 已绑定,放过
            self.finishUnboundInboundConnection(
                conn,
                lifecycle: lifecycle,
                generation: generation,
                event: .timeout,
                failure: "入站连接超时"
            )
        }
    }

    private func finishUnboundInboundConnection(
        _ conn: TransferConnection,
        lifecycle: TransferReconnectExecutionPolicy.InboundConnectionLifecycle,
        generation: UInt,
        event: TransferReconnectExecutionPolicy.InboundTerminalEvent,
        failure: String
    ) {
        guard serviceGeneration.accepts(generation) else {
            conn.cancel()
            return
        }
        let decision = lifecycle.terminalDecision(
            for: event,
            source: conn,
            activePairing: activePairingConn,
            activeBound: activeConn
        )
        switch decision {
        case .ignoreSilently, .ignoreStale:
            if event == .timeout { conn.cancel() }
        case .finishPairingFailure:
            activePairing = nil
            activePairingConn = nil
            conn.cancel()
            connectionState = .failed(failure)
            resumeDeferredAutomaticRecoveryIfPossible()
        case .publishFailure:
            logger.log(.warn, tool: "transfer", failure)
            conn.cancel()
            connectionState = .failed(failure)
        }
    }

    private func inboundReady(
        conn: TransferConnection,
        lifecycle: TransferReconnectExecutionPolicy.InboundConnectionLifecycle,
        generation: UInt
    ) {
        guard serviceGeneration.accepts(generation) else {
            conn.cancel()
            return
        }
        guard let fp = conn.peerFingerprint else {
            logger.log(.warn, tool: "transfer", "③✗ 入站 .ready 但读不到对端证书指纹(就卡这里,静默返回)")
            return
        }
        logger.log(.info, tool: "transfer", "③✓ 入站读到对端指纹 \(fp.prefix(8))…")
        if case .connected = connectionState, let ac = activeConn, ac !== conn {
            if fp != activePeerFingerprint {   // 已与他人连接,拒绝陌生入站,避免污染当前会话
                conn.cancel(); return
            }
            // 同一对端重连:继续往下走(会在 bindConnected 里替换旧连接)
        }
        if let paired = peerStore.peer(forFingerprint: fp) {
            let peerRef = TransferAutoReconnect.PeerRef(
                deviceId: paired.deviceId,
                fingerprint: paired.fingerprint
            )
            switch TransferReconnectExecutionPolicy.inboundDecision(
                isPairedCodeless: true,
                locallyAllowed: reconnectCoordinator.allowsInbound(peerRef)
            ) {
            case .rejectAndCancel:
                guard lifecycle.rejectSilently(conn) else {
                    conn.cancel()
                    return
                }
                logger.log(
                    .info,
                    tool: "transfer",
                    "拒绝用户主动断开设备的自动回连：\(paired.name)"
                )
                conn.cancel()
            case .acceptCodeless:
                bindConnected(conn: conn, peer: paired)
            case .continuePairing:
                assertionFailure("已配对免码路径不应进入首次配对")
                conn.cancel()
            }
        } else {
            // 全局限速:静默取消,不向攻击者暴露(避免每换证书绕过 per-fp 冷却)。
            if isGloballyCoolingDown() {
                logger.log(.warn, tool: "transfer", "配对尝试过多,已临时拒绝入站配对请求")
                conn.cancel(); return
            }
            if isCoolingDown(fp) {
                logger.log(.warn, tool: "transfer", "该对端配对失败过多,冷却中,拒绝入站 \(fp.prefix(8))…")
                conn.cancel(); return
            }
            // 常驻配对码:启动时已生成并持续显示给对端读取,此处不轮换,
            // 否则对端正照着屏幕输入时码却变了,必然配对失败。仅作 nil 兜底。
            if pendingPairingCode == nil { pendingPairingCode = PairingCrypto.makeCode(); pairingCodeIssuedAt = Date() }
            logger.log(.info, tool: "transfer", "④ 入站配对开始,本机码 \(pendingPairingCode!),发 hello/pairOffer 给对端")
            startPairing(conn: conn, code: pendingPairingCode!, peerFingerprint: fp)
        }
    }

    // MARK: - 配对

    private func startPairing(
        conn: TransferConnection,
        code: String,
        peerFingerprint fp: String,
        outboundAttempt: ActiveOutboundAttempt? = nil
    ) {
        // 并发入站:若已有另一条连接正在配对,顶替(supersede)旧的,避免旧连接被孤立永不收尾。
        if let oldConn = activePairingConn, oldConn !== conn {
            activePairingConn = nil
            oldConn.cancel()
        }
        activePairing = nil
        connectionState = .pairing
        let selfId: DeviceIdentity.Loaded
        do {
            selfId = try identity()
        } catch {
            if let outboundAttempt {
                finishOutboundAttempt(
                    id: outboundAttempt.id,
                    conn: conn,
                    origin: outboundAttempt.origin,
                    failure: "身份加载失败"
                )
            } else {
                conn.cancel()
                connectionState = .failed("身份加载失败")
                resumeDeferredAutomaticRecoveryIfPossible()
            }
            return
        }
        let pm = PairingManager(code: code, selfFingerprint: selfId.fingerprint,
                                selfDeviceId: identityStore.deviceId, selfName: deviceName,
                                peerFingerprint: fp)
        pm.send = { [weak conn] msg in conn?.send(msg) }
        pm.onOutcome = { [weak self] outcome in
            DispatchQueue.main.async {
                self?.finishPairing(
                    conn: conn,
                    fp: fp,
                    outcome: outcome,
                    outboundAttempt: outboundAttempt
                )
            }
        }
        activePairing = pm
        activePairingConn = conn   // 强持有,保证配对期间 pm/conn 不被并发入站释放
        // 先装 onMessage 再 begin() —— 镜像 loopback 已验证的顺序,避免漏掉对端首条消息。
        // 强捕获 pm:连接持有该闭包即维持 pm 存活;pm.send 为 [weak conn]、onOutcome 为 [weak self],无循环引用。
        conn.onMessage = { msg in pm.handle(msg) }
        pm.begin()
    }

    private func finishPairing(
        conn: TransferConnection,
        fp: String,
        outcome: PairingManager.Outcome,
        outboundAttempt: ActiveOutboundAttempt?
    ) {
        guard activePairingConn === conn else { return }
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
            bindConnected(conn: conn, peer: peer, outboundAttempt: outboundAttempt)
            logger.log(.info, tool: "transfer", "已与 \(peer.name) 配对")
        case let .failed(reason):
            failureCounts[fp, default: 0] += 1
            if failureCounts[fp]! >= 3 { cooldownUntil[fp] = Date().addingTimeInterval(60) }
            recordPairFailure()    // 全局(与指纹无关)滑动窗口限速
            // 常驻码:失败不轮换,保持显示同一码,方便对端照着重试(防爆破已有冷却兜底)。
            if let outboundAttempt {
                finishOutboundAttempt(
                    id: outboundAttempt.id,
                    conn: conn,
                    origin: outboundAttempt.origin,
                    failure: reason
                )
            } else {
                conn.cancel()
                if activeConn === conn { activeConn = nil }
                connectionState = .failed(reason)
                resumeDeferredAutomaticRecoveryIfPossible()
            }
            logger.log(.warn, tool: "transfer", "配对失败: \(reason)")
        }
    }

    private func bindConnected(
        conn: TransferConnection,
        peer: PairedPeer,
        outboundAttempt: ActiveOutboundAttempt? = nil
    ) {
        guard TransferReconnectExecutionPolicy.allowsSessionActivity(
            servicesRunning: servicesRunning,
            stopRequested: stopRequested
        ) else {
            conn.cancel()
            return
        }
        if let outboundAttempt {
            guard activeOutboundAttempt?.id == outboundAttempt.id,
                  activeOutboundAttempt?.origin == outboundAttempt.origin,
                  conn === activeConn else { return }
        }
        cancelReconnectScheduling()
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
        if let old = activeConn, old !== conn {
            activeConn = nil
            activeOutboundAttempt = nil
            old.cancel()
        }
        activeOutboundAttempt = nil
        connectionState = .connected(peerName: peer.name)
        activeConn = conn
        activePeerFingerprint = peer.fingerprint
        let peerRef = TransferAutoReconnect.PeerRef(
            deviceId: peer.deviceId,
            fingerprint: peer.fingerprint
        )
        lastConnectedPeer = peerRef
        reconnectCoordinator.connected(
            to: peerRef,
            endpointKey: discoveredPeer(matching: peerRef)?.reconnectEndpointKey
        )
        if let outboundAttempt, outboundAttempt.origin == .user,
           let manualRetryRequest {
            self.manualRetryRequest = TransferManualRetryPolicy.afterSuccessfulBind(
                manualRetryRequest
            )
        }
        // 绑定后统一接管断开收尾(覆盖 acceptInbound/beginOutbound 的 pre-bind 回调),
        // 入站/出站均处理:出站 .cancelled 也曾被忽略,入站 .cancelled 之前完全没有收尾。
        conn.onStateChange = { [weak self, weak conn] st in
            guard let self, let conn else { return }
            switch st {
            case .failed(let e):
                DispatchQueue.main.async {
                    self.handleBoundConnectionDrop(conn, failure: "连接断开: \(e)")
                }
            case .cancelled:
                DispatchQueue.main.async {
                    self.handleBoundConnectionDrop(conn, failure: nil)
                }
            default:
                break
            }
        }
        conn.onBinary = { [weak self] data in self?.fileManager.handleBinary(data) }
        // 已绑定连接的入站路由:数据帧照常处理;若对端在此连接上(重新)发起配对,就地补一个应答方握手,
        // 避免「一端在配对、另一端已绑定」的角色错位把对端拖到配对超时(死锁)。
        // 在主线程(本方法)先把配对所需的不可变量捕获好,makePairing 构造应答方时不读可变服务状态,
        // 故可安全地从连接的网络队列惰性调用;onOutcome 自行跳回主线程(见 handleBoundRepair)。
        let code = pendingPairingCode ?? ""
        let selfId = try? identity()
        let myDeviceId = identityStore.deviceId
        let myName = deviceName
        let router = BoundInboundRouter(makePairing: { [weak self, weak conn] in
            guard let conn, let selfId else { return nil }
            let pm = PairingManager(code: code, selfFingerprint: selfId.fingerprint,
                                    selfDeviceId: myDeviceId, selfName: myName,
                                    peerFingerprint: peer.fingerprint)
            pm.send = { [weak conn] msg in conn?.send(msg) }
            pm.onOutcome = { [weak self] outcome in
                DispatchQueue.main.async { self?.handleBoundRepair(peer: peer, outcome: outcome) }
            }
            return pm
        })
        router.onData = { [weak self, weak conn] msg in
            guard let self, let conn else { return }
            switch msg {
            case let .clipboardText(text, hash):
                DispatchQueue.main.async { self.receiveClipboard(text: text, hash: hash, peerName: peer.name) }
            case let .fileOffer(id, name, size):
                self.fileManager.handleOffer(id: id, name: name, size: size, isImage: false)
            case let .clipboardImageOffer(id, size, _):
                self.fileManager.handleOffer(id: id, name: "image-\(id).png", size: size, isImage: true)
            case let .fileComplete(id):
                self.fileManager.handleComplete(id: id)
            case .bye:
                DispatchQueue.main.async {
                    self.handlePeerBye(peer: peer, source: conn)
                }
            default:
                break
            }
        }
        conn.onMessage = { router.handle($0) }   // 强捕获 router:连接持有该闭包即维持其与内部 pm 存活
    }

    private func handleBoundConnectionDrop(
        _ conn: TransferConnection,
        failure: String?
    ) {
        guard conn === activeConn else { return }
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
        activeConn = nil
        activeOutboundAttempt = nil
        activePeerFingerprint = nil
        activePairing = nil
        if activePairingConn === conn { activePairingConn = nil }
        fileManager.reset()
        conn.cancel()
        connectionState = failure.map(ConnectionState.failed) ?? .idle

        guard TransferReconnectExecutionPolicy.allowsSessionActivity(
            servicesRunning: servicesRunning,
            stopRequested: stopRequested
        ), reconnectCoordinator.target != nil else { return }
        requestAutomaticRecovery(unexpectedDrop: true)
    }

    /// 对端主动断开(收到 .bye):尊重对端的「断开」意图,本机不再自动重连它。连接随后会被对端 cancel,
    /// 由 handleBoundConnectionDrop 收尾回 idle;此处不强行 cancel,避免与收尾竞态。
    private func handlePeerBye(
        peer: PairedPeer,
        source: TransferConnection
    ) {
        guard TransferReconnectExecutionPolicy.boundMessageDecision(
            source: source,
            active: activeConn
        ) == .handle else { return }
        let peerRef = TransferAutoReconnect.PeerRef(
            deviceId: peer.deviceId,
            fingerprint: peer.fingerprint
        )
        cancelReconnectScheduling()
        reconnectCoordinator.peerSaidBye(peerRef)
        if lastConnectedPeer == peerRef { lastConnectedPeer = nil }
        logger.log(.info, tool: "transfer", "对端 \(peer.name) 主动断开,停止对其自动重连")
    }

    /// 已连接通道上对端发起的「重新配对」结果。连接已绑定,无需再 bindConnected:
    /// 成功仅刷新已配对信息并轮换配对码(与 finishPairing 一致);失败仅记账,不主动断开
    /// (这条连接的数据通道仍可用,贸然断开反而打断正常使用;对端若不满意会自行 cancel)。
    private func handleBoundRepair(peer: PairedPeer, outcome: PairingManager.Outcome) {
        switch outcome {
        case let .success(repaired):
            failureCounts[repaired.fingerprint] = 0
            peerStore.upsert(repaired)
            pairedPeers = peerStore.all()
            pendingPairingCode = PairingCrypto.makeCode()
            pairingCodeIssuedAt = Date()
            logger.log(.info, tool: "transfer", "对端在已连接通道上完成重新配对 \(repaired.name)")
        case let .failed(reason):
            recordPairFailure()
            logger.log(.warn, tool: "transfer", "对端在已连接通道上发起的重新配对失败: \(reason)")
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

    /// 按保留天数清理历史与 inbox 文件(0 = 永久,不清理)。启动时跑一次,之后由定时器每 6 小时跑。
    private func cleanupOldHistory() {
        let days = UserDefaults.standard.integer(forKey: "transferRetentionDays")
        guard days > 0 else { return }   // 0 = 永久保留(用户显式选择)
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let kept = historyStore.pruning(history, olderThan: cutoff)
        if kept.count != history.count {
            history = kept; historyStore.save(history)
        }
        TransferPaths.pruneFiles(in: TransferPaths.inbox, olderThan: cutoff)
    }

    /// 每 6 小时定时跑一次按天清理(配合启动时的一次),常驻后台也能持续回收旧文件。
    private func startCleanupTimer() {
        cleanupTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 6 * 3600, repeating: 6 * 3600)
        t.setEventHandler { [weak self] in self?.cleanupOldHistory() }
        t.resume()
        cleanupTimer = t
    }

    func clearHistory() {
        history = []; historyStore.clear()
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: TransferPaths.inbox, includingPropertiesForKeys: nil) {
            for f in files { try? fm.removeItem(at: f) }
        }
    }

    func clearPairedDevices() {
        cancelReconnectScheduling()
        for peer in peerStore.all() {
            reconnectCoordinator.clearPeer(.init(
                deviceId: peer.deviceId,
                fingerprint: peer.fingerprint
            ))
        }
        peerStore.removeAll()
        pairedPeers = []
        lastConnectedPeer = nil
    }

    // MARK: - 生命周期动作

    private var hasBoundConnection: Bool {
        activeConn != nil && activePeerFingerprint != nil
    }

    private var hasActiveAutomaticAttempt: Bool {
        guard let activeOutboundAttempt else { return false }
        if case .automatic = activeOutboundAttempt.origin { return true }
        return false
    }

    private var discoverySessionDisposition: TransferReconnectExecutionPolicy.DiscoverySessionDisposition {
        TransferReconnectExecutionPolicy.discoverySessionDisposition(
            connectionState: connectionState,
            hasBoundConnection: hasBoundConnection,
            activeOrigin: activeOutboundAttempt?.origin,
            hasActivePairingConnection: activePairingConn != nil
        )
    }

    private func executeLifecycleActions(
        _ actions: [TransferReconnectExecutionPolicy.LifecycleAction]
    ) {
        for action in actions {
            switch action {
            case .invalidateRecovery:
                cancelReconnectScheduling()
                reconnectCoordinator.cancelAutomaticRecovery()
                connectTimeoutWork?.cancel()
                connectTimeoutWork = nil
                if !hasBoundConnection {
                    cleanupUnboundConnectionForLifecycle()
                }
            case .suppressCurrentPeer:
                if let peer = lastConnectedPeer {
                    reconnectCoordinator.userDisconnected(from: peer)
                    lastConnectedPeer = nil
                }
            case .sendByeThenClose:
                sendByeThenCloseBoundConnection()
            case .stopServices:
                stopServicesNow()
            }
        }
        if !actions.contains(.stopServices) {
            connectionState = .idle
        }
    }

    private func cleanupUnboundConnectionForLifecycle() {
        if let attempt = activeOutboundAttempt {
            finishOutboundAttempt(
                id: attempt.id,
                conn: activeConn,
                origin: attempt.origin,
                failure: "连接已取消"
            )
        } else if let conn = activeConn {
            activeConn = nil
            conn.cancel()
        }
        activePairing = nil
        if let pairingConn = activePairingConn {
            activePairingConn = nil
            if pairingConn !== activeConn { pairingConn.cancel() }
        }
        activePeerFingerprint = nil
        fileManager.reset()
    }

    private func sendByeThenCloseBoundConnection() {
        guard let conn = activeConn else { return }
        activeConn = nil
        activeOutboundAttempt = nil
        activePeerFingerprint = nil
        activePairing = nil
        if activePairingConn === conn { activePairingConn = nil }
        fileManager.reset()
        connectionState = .idle

        let closeOnce = TransferConnectionCloseOnce(conn)
        conn.send(.bye) { _ in
            DispatchQueue.main.async {
                closeOnce.close()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            closeOnce.close()
        }
    }

    private func stopServicesNow() {
        serviceGeneration.stop()
        cancelReconnectScheduling()
        reconnectCoordinator.stop()
        lastConnectedPeer = nil
        networkPathBridge.deactivate()
        networkMonitor.stop()
        networkPathSatisfied = nil
        removeLifecycleObservers()
        cleanupTimer?.cancel()
        cleanupTimer = nil
        monitor.stop()
        discovery.stop()
        discovery.onPeersChanged = nil
        discovery.onFailure = nil
        discoveredPeers = []
        server?.stop()
        server = nil
        client = nil
        listenPort = nil
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
        if let conn = activeConn {
            activeConn = nil
            conn.cancel()
        }
        activeOutboundAttempt = nil
        activePeerFingerprint = nil
        fileManager.reset()
        activePairing = nil
        activePairingConn?.cancel()
        activePairingConn = nil
        manualRetryRequest = nil
        lastManualConnect = nil
        pendingPairingCode = nil
        pairingCodeIssuedAt = nil
        lastBonjourRepairAt = nil
        connectionState = .idle
    }

    // MARK: - 自动恢复事件与动作

    private func discoveredPeer(
        matching peer: TransferAutoReconnect.PeerRef,
        in peers: [DiscoveredPeer]? = nil
    ) -> DiscoveredPeer? {
        (peers ?? discoveredPeers).first {
            $0.deviceId == peer.deviceId && $0.fingerprint == peer.fingerprint
        }
    }

    private func handleDiscoveredPeers(_ peers: [DiscoveredPeer]) {
        guard servicesRunning else { return }
        let sessionDisposition = discoverySessionDisposition
        let target = reconnectCoordinator.target
        let oldPeer = target.flatMap { discoveredPeer(matching: $0) }
        let newPeer = target.flatMap { discoveredPeer(matching: $0, in: peers) }
        discoveredPeers = peers

        guard let target else { return }
        if oldPeer != nil, newPeer == nil {
            cancelReconnectScheduling()
            reconnectCoordinator.peerBecameUnavailable()
            if sessionDisposition == .automatic {
                cleanupUnboundAutomaticAttempt()
            }
            if !sessionDisposition.preservesPresentation {
                showWaitingForRecovery("等待设备重新出现")
            }
            return
        }
        if let newPeer {
            executeDiscoveryEndpointActions(
                TransferReconnectExecutionPolicy.discoveryEndpointActions(
                    oldEndpointKey: oldPeer?.reconnectEndpointKey,
                    newEndpointKey: newPeer.reconnectEndpointKey,
                    hasBoundConnection: hasBoundConnection,
                    hasActiveAutomaticAttempt: hasActiveAutomaticAttempt
                ),
                target: target,
                newEndpointKey: newPeer.reconnectEndpointKey,
                sessionDisposition: sessionDisposition
            )
        }
    }

    private func executeDiscoveryEndpointActions(
        _ actions: [TransferReconnectExecutionPolicy.DiscoveryEndpointAction],
        target: TransferAutoReconnect.PeerRef,
        newEndpointKey: String,
        sessionDisposition: TransferReconnectExecutionPolicy.DiscoverySessionDisposition
    ) {
        for action in actions {
            switch action {
            case .invalidateAutomaticRecovery:
                cancelReconnectScheduling()
                reconnectCoordinator.peerBecameUnavailable()
            case .cleanupAutomaticAttempt:
                cleanupUnboundAutomaticAttempt()
            case .recordBoundEndpoint:
                reconnectCoordinator.connected(
                    to: target,
                    endpointKey: newEndpointKey
                )
            case .requestRecovery:
                if sessionDisposition.allowsAutomaticRecovery {
                    requestAutomaticRecovery()
                }
            }
        }
    }

    private func handleDiscoveryFailure(_ error: Error) {
        guard servicesRunning else { return }
        let sessionDisposition = discoverySessionDisposition
        cancelReconnectScheduling()
        if reconnectCoordinator.target != nil {
            reconnectCoordinator.peerBecameUnavailable()
        }
        if sessionDisposition == .automatic {
            cleanupUnboundAutomaticAttempt()
        }
        discoveredPeers = []
        logger.log(.warn, tool: "transfer", "Bonjour 浏览失败: \(error.localizedDescription)")
        if !sessionDisposition.preservesPresentation {
            showWaitingForRecovery("等待设备重新出现")
        }
    }

    fileprivate func handleNetworkPath(
        _ isSatisfied: Bool,
        transition: TransferNetworkTransition
    ) {
        guard servicesRunning else { return }
        networkPathSatisfied = isSatisfied
        let event: TransferReconnectExecutionPolicy.RecoveryEvent
        switch transition {
        case .becameUnavailable:
            event = .pathUnavailable
        case .restored:
            event = .pathRestored(reassertBonjour: shouldReassertBonjourNow())
        case .initial where isSatisfied:
            event = .initialSatisfied(reassertBonjour: shouldReassertBonjourNow())
        case .initial, .unchanged:
            return
        }
        executeRecoveryActions(
            TransferReconnectExecutionPolicy.actions(for: event)
        )
    }

    private func shouldReassertBonjourNow() -> Bool {
        TransferReconnectExecutionPolicy.shouldReassertBonjour(
            last: lastBonjourRepairAt,
            now: ProcessInfo.processInfo.systemUptime,
            minimumInterval: 3
        )
    }

    private func executeRecoveryActions(
        _ actions: [TransferReconnectExecutionPolicy.RecoveryAction]
    ) {
        for action in actions {
            switch action {
            case .cancelRecovery:
                cancelReconnectScheduling()
            case .invalidateForNetworkLoss:
                reconnectCoordinator.networkUnavailable()
            case .cleanupCurrentConnection:
                cleanupCurrentConnectionForNetworkLoss()
            case .waitForEvent:
                showWaitingForRecovery("网络不可用，等待网络恢复")
            case .repairListener:
                server?.restartIfUnhealthy()
            case .reassertBonjour:
                lastBonjourRepairAt = ProcessInfo.processInfo.systemUptime
                server?.setAdvertising(!stealthMode)
            case .restartDiscovery:
                discovery.start()
            case .requestRecovery:
                requestAutomaticRecovery()
            }
        }
    }

    private func cleanupCurrentConnectionForNetworkLoss() {
        if let attempt = activeOutboundAttempt {
            finishOutboundAttempt(
                id: attempt.id,
                conn: activeConn,
                origin: attempt.origin,
                failure: "网络连接已中断"
            )
        } else if let conn = activeConn {
            activeConn = nil
            activePeerFingerprint = nil
            fileManager.reset()
            conn.cancel()
        }
        activePairing = nil
        if let pairingConn = activePairingConn {
            activePairingConn = nil
            if pairingConn !== activeConn { pairingConn.cancel() }
        }
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
    }

    private func cleanupUnboundAutomaticAttempt() {
        guard activePeerFingerprint == nil,
              let attempt = activeOutboundAttempt,
              case .automatic = attempt.origin else { return }
        finishOutboundAttempt(
            id: attempt.id,
            conn: activeConn,
            origin: attempt.origin,
            failure: "自动恢复目标已变化"
        )
    }

    private func currentAutomaticTarget() -> DiscoveredPeer? {
        TransferAutoReconnect.target(
            busy: connectionState.isBusy,
            userStopped: stopRequested,
            selfDeviceId: identityStore.deviceId,
            last: lastConnectedPeer,
            discovered: discoveredPeers,
            pairedFingerprints: Set(pairedPeers.map(\.fingerprint))
        )
    }

    private func requestAutomaticRecovery(unexpectedDrop: Bool = false) {
        let target = currentAutomaticTarget()
        let endpointKey = target?.reconnectEndpointKey
        let command: TransferReconnectCoordinator.Command
        if unexpectedDrop {
            command = reconnectCoordinator.unexpectedDrop(
                pathSatisfied: networkPathSatisfied == true,
                canDial: target != nil,
                endpointKey: endpointKey
            )
        } else {
            command = reconnectCoordinator.recoveryEvent(
                pathSatisfied: networkPathSatisfied == true,
                canDial: target != nil,
                busy: connectionState.isBusy,
                endpointKey: endpointKey
            )
        }
        executeReconnect(command)
    }

    private func resumeDeferredAutomaticRecoveryIfPossible() {
        guard let token = reconnectCoordinator.deferredToken,
              TransferReconnectExecutionPolicy.mayResumeDeferredRecovery(
                  tokenAccepted: reconnectCoordinator.accepts(token),
                  servicesRunning: servicesRunning,
                  userStopped: stopRequested,
                  busy: connectionState.isBusy,
                  hasActiveConnection: activeConn != nil,
                  hasActivePairing: activePairing != nil,
                  hasActivePairingConnection: activePairingConn != nil,
                  hasBoundConnection: hasBoundConnection
              ) else { return }
        let target = currentAutomaticTarget()
        executeReconnect(
            reconnectCoordinator.resumeDeferredRecovery(
                token,
                pathSatisfied: networkPathSatisfied == true,
                canDial: target != nil,
                endpointKey: target?.reconnectEndpointKey
            )
        )
    }

    private func executeReconnect(_ command: TransferReconnectCoordinator.Command) {
        switch command {
        case .none:
            return
        case .waitForEvent:
            cancelReconnectScheduling()
            showWaitingForRecovery(nil)
        case let .schedule(token, delay):
            cancelReconnectScheduling()
            reconnectScheduledToken = token
            connectionState = .failed("连接断开，等待自动恢复…")
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      self.reconnectScheduledToken == token else { return }
                self.reconnectWork = nil
                self.reconnectScheduledToken = nil
                self.executeReconnect(self.reconnectCoordinator.delayElapsed(token))
            }
            reconnectWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        case let .dial(token):
            cancelReconnectScheduling()
            let target = currentAutomaticTarget()
            let currentPeer = target.map {
                TransferAutoReconnect.PeerRef(
                    deviceId: $0.deviceId,
                    fingerprint: $0.fingerprint
                )
            }
            let currentEndpointKey = target?.reconnectEndpointKey
            let tokenAccepted = reconnectCoordinator.accepts(token)
            let decision = TransferReconnectExecutionPolicy.automaticDialDecision(
                token: token,
                tokenAccepted: tokenAccepted,
                busy: connectionState.isBusy,
                hasActiveConnection: activeConn != nil,
                pathSatisfied: networkPathSatisfied == true,
                currentPeer: currentPeer,
                currentEndpointKey: currentEndpointKey
            )
            switch decision {
            case .ignore:
                return
            case .deferCurrentAttempt:
                reconnectCoordinator.deferDial(token)
                return
            case .targetChanged:
                reconnectCoordinator.peerBecameUnavailable()
                cleanupUnboundAutomaticAttempt()
                requestAutomaticRecovery()
                return
            case .targetUnavailable:
                reconnectCoordinator.peerBecameUnavailable()
                cleanupUnboundAutomaticAttempt()
                showWaitingForRecovery("等待设备重新出现")
                return
            case .waitForEvent:
                reconnectCoordinator.networkUnavailable()
                showWaitingForRecovery("网络不可用，等待网络恢复")
                return
            case .start:
                break
            }
            guard let target else { return }
            logger.log(.info, tool: "transfer", "自动重连(免码)→ \(target.name), attempt \(token.attempt)")
            performOutbound(
                to: target,
                pairingCode: nil,
                origin: .automatic(token)
            )
        }
    }

    private func cancelReconnectScheduling() {
        reconnectWork?.cancel()
        reconnectWork = nil
        reconnectScheduledToken = nil
    }

    private func showWaitingForRecovery(_ detail: String?) {
        let message = detail ?? "等待设备重新出现或网络恢复"
        connectionState = .failed(message)
    }

    private func onWokeOrActivated(_ reason: String) {
        guard servicesRunning else { return }
        logger.log(.info, tool: "transfer", "\(reason):检查监听/广播与自动恢复")
        let event = TransferReconnectExecutionPolicy.RecoveryEvent.wake(
            reassertBonjour: shouldReassertBonjourNow()
        )
        executeRecoveryActions(
            TransferReconnectExecutionPolicy.actions(for: event)
        )
    }

    deinit { removeLifecycleObservers() }   // 兜底:本对象虽为 App 生命周期常驻,仍对称移除观察者

    private func installLifecycleObservers() {
        if appActiveObserver == nil {
            appActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.onWokeOrActivated("前台活跃") }
        }
        if didWakeObserver == nil {
            didWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.onWokeOrActivated("系统睡醒") }
        }
    }

    private func removeLifecycleObservers() {
        if let o = appActiveObserver { NotificationCenter.default.removeObserver(o); appActiveObserver = nil }
        if let o = didWakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); didWakeObserver = nil }
    }

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

/// 本机局域网地址工具:供「本机」卡片展示,方便对端手动填 IP + 端口连接。
enum LocalNetwork {
    /// 活跃的局域网 IPv4(优先 Wi-Fi en0,其次有线 en1…)。取不到返回 nil。
    static func lanIPv4() -> String? {
        var candidates: [(iface: String, ip: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr else { continue }
            let flags = Int32(ptr.pointee.ifa_flags)
            // 仅 up + running 且非回环
            guard (flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == (IFF_UP | IFF_RUNNING) else { continue }
            guard sa.pointee.sa_family == UInt8(AF_INET) else { continue }   // 仅 IPv4
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }                     // 物理网卡(Wi-Fi/有线)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            candidates.append((name, String(cString: host)))
        }
        return candidates.sorted { $0.iface < $1.iface }.first?.ip   // en0 在前
    }
}
