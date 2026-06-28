import Foundation
import Network
import Security
import AppKit

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
    private var cleanupTimer: DispatchSourceTimer?   // 定时按保留天数回收历史/inbox 文件
    private var lastReconnect: (() -> Void)?
    private var lastManualConnect: (() -> Void)?     // UI「重试」:原样重放上次用户发起的连接(含当时的配对码)
    private var reconnectAttempts = 0
    private var reconnectGeneration = 0
    private var userStopped = false
    private var wasConnected = false
    // 自动(免码)重连:记住「最后一次成功连上的那台」,前台/睡醒/Bonjour 重新发现时免码重连它。
    // 见 TransferAutoReconnect.target 的纯决策与 maybeAutoReconnect 的触发装配。
    private var lastConnectedPeer: TransferAutoReconnect.PeerRef?
    private var lastAutoReconnectAt: Date?            // 自动重连冷却,避免发现回调/前台事件密集触发成紧密循环
    private var lastDiscoveryRefreshAt: Date?         // 前台/睡醒重启 Bonjour 浏览的去抖(didBecomeActive 很频繁)
    private var lastReassertAt: Date?                 // 睡醒/前台重新广播的去抖(避免每次获焦都重注册 Bonjour,致对端发现抖动)
    private var autoReconnecting = false              // 本次出站是否为「静默自动重连」:失败时不弹红条,静默回落 .idle
    private var appActiveObserver: NSObjectProtocol?  // NSApplication.didBecomeActive
    private var didWakeObserver: NSObjectProtocol?    // NSWorkspace.didWake(系统睡醒)

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
    /// 单写者假设:`loadedIdentity` 由上面的后台线程在调用 startServices 之前写入一次,此后只读不再改。
    /// 故后续 `identity()` 即便被 server 的 `{ try self.identity().identity }` 闭包在 transfer.server 队列上
    /// (listener 自愈/重建时)调用,也只是读取这份「初始化后即不变」的缓存引用,无写竞态,无需加锁。
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
            // listener 重建(.failed 自愈 / 睡醒)会换端口:.ready 时把新端口同步到 @Published 显示;
            // 掉线置 nil,避免「本机」卡片继续展示一个已失效的端口。
            server.onStateChange = { [weak self] st, port in
                DispatchQueue.main.async {
                    switch st {
                    case .ready:                 self?.listenPort = port
                    case .failed, .cancelled:    self?.listenPort = nil
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
            // 启动 Bonjour 浏览,发现局域网内其它 EasySign 设备。
            // 列表变化时除刷新 UI 外,顺带尝试免码自动重连「最后那台」(它若刚重新出现就接上)。
            discovery.onPeersChanged = { [weak self] peers in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.discoveredPeers = peers
                    self.maybeAutoReconnect()
                }
            }
            discovery.start()
            installLifecycleObservers()
            monitor.start()
            // 监听端口由 server.onStateChange 的 .ready 同步到 listenPort(见上),无需再轮询 server.port(跨线程读)。
            logger.log(.info, tool: "transfer", "互传服务已启动,本机指纹 \(id.fingerprint.prefix(8))…")
        } catch {
            logger.log(.error, tool: "transfer", "启动失败: \(error)")
            connectionState = .failed("启动失败: \(error.localizedDescription)")
        }
        cleanupOldHistory()
        startCleanupTimer()
    }

    func stop() {
        userStopped = true
        reconnectGeneration += 1      // 取消任何挂起的重连
        wasConnected = false
        autoReconnecting = false
        lastConnectedPeer = nil       // 停服:清掉自动重连目标
        removeLifecycleObservers()
        connectTimeoutWork?.cancel(); connectTimeoutWork = nil
        cleanupTimer?.cancel(); cleanupTimer = nil
        monitor.stop()
        discovery.stop()
        discoveredPeers = []
        server?.stop(); server = nil
        listenPort = nil              // 监听已停:清掉「本机」卡片上的端口显示
        activeConn?.cancel(); activeConn = nil
        activePeerFingerprint = nil
        fileManager.reset()
        activePairing = nil
        activePairingConn?.cancel(); activePairingConn = nil
        pendingPairingCode = nil
        pairingCodeIssuedAt = nil
        connectionState = .idle
    }

    /// 断开当前连接但不停服务、不解除配对:回到"未连接",对端仍在已配对列表,可一键重连。
    /// 与 stop() 不同——监听/发现/剪贴板继续运行,本机仍可被发现、可主动或被动重新连接。
    func disconnect() {
        userStopped = true            // 阻止本次断开触发自动重连
        reconnectGeneration += 1      // 撤销任何挂起的重连
        autoReconnecting = false
        lastConnectedPeer = nil       // 主动断开:本机不再自动重连这台
        connectTimeoutWork?.cancel(); connectTimeoutWork = nil
        wasConnected = false
        let c = activeConn; activeConn = nil   // 先置空,使断开回调的 guard 失效,避免重复收尾
        activePeerFingerprint = nil
        activePairing = nil
        let pc = activePairingConn; activePairingConn = nil
        // 先告知对端「我主动断开」,让对端也清掉自动重连目标(否则对端的「发现即连」会把本机又拉回来)。
        // bye 必须在关闭前真正写出去:在 send 完成回调里关闭(冲刷后再 cancel),再挂 0.5s 兜底
        // (回调因连接半死不来时也能收口)。两路都走 closeOnce,只 cancel 一次(且 cancel 本身幂等)。
        if let c {
            var closed = false
            let closeOnce: () -> Void = { if !closed { closed = true; c.cancel() } }
            c.send(.bye) { _ in DispatchQueue.main.async(execute: closeOnce) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: closeOnce)
        }
        pc?.cancel()
        fileManager.reset()
        connectionState = .idle
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
        // 一次用户主动连接 = 取消上次的"已停止"并清零重连计数、撞代际取消任何挂起重连。
        autoReconnecting = false      // 用户主动发起:失败要可见(红条 + 重试)
        reconnectGeneration += 1
        reconnectAttempts = 0
        userStopped = false
        wasConnected = false
        lastReconnect = { [weak self] in self?.performOutbound(host: host, port: port, pairingCode: nil) }
        lastManualConnect = { [weak self] in self?.connect(host: host, port: port, pairingCode: pairingCode) }
        performOutbound(host: host, port: port, pairingCode: pairingCode)
    }

    /// UI「重试」:原样重放上次用户发起的连接(含当时输入的配对码)。失败态下由状态条上的按钮调用。
    func retry() { lastManualConnect?() }
    var canRetry: Bool { lastManualConnect != nil }

    private func performOutbound(host: String, port: UInt16, pairingCode: String?) {
        activeConn?.cancel()
        activeConn = nil
        guard let client else { return }
        connectionState = pairingCode == nil ? .connecting : .pairing
        logger.log(.info, tool: "transfer", "发起出站连接 → \(host):\(port)(\(pairingCode == nil ? "无码/重连" : "配对码"))")
        do {
            let conn = try client.connect(host: host, port: port, pin: .acceptAny)
            beginOutbound(conn, pairingCode: pairingCode)
        } catch {
            logger.log(.error, tool: "transfer", "出站连接创建失败: \(error.localizedDescription)")
            failState("连接失败: \(error.localizedDescription)")
        }
    }

    /// 连接 Bonjour 发现出的对端。复用与手动 IP 完全相同的配对/pinning 流程(`.acceptAny` → 读指纹 → 配对/绑定)。
    /// 用户点「连接」/「重试」走这里(auto=false,失败可见);静默自动重连由 maybeAutoReconnect 用 auto=true 调私有重载。
    func connect(to peer: DiscoveredPeer, pairingCode: String?) {
        connect(to: peer, pairingCode: pairingCode, auto: false)
    }

    private func connect(to peer: DiscoveredPeer, pairingCode: String?, auto: Bool) {
        autoReconnecting = auto
        reconnectGeneration += 1
        reconnectAttempts = 0
        userStopped = false
        wasConnected = false
        lastReconnect = { [weak self] in self?.performOutbound(to: peer, pairingCode: nil) }
        // 用户重试 = 非 auto(失败可见);故指向公开重载。
        lastManualConnect = { [weak self] in self?.connect(to: peer, pairingCode: pairingCode) }
        performOutbound(to: peer, pairingCode: pairingCode)
    }

    private func performOutbound(to peer: DiscoveredPeer, pairingCode: String?) {
        activeConn?.cancel()
        activeConn = nil
        guard let client else { return }
        connectionState = pairingCode == nil ? .connecting : .pairing
        logger.log(.info, tool: "transfer", "发起出站连接(Bonjour)→ \(String(describing: peer.endpoint))(\(pairingCode == nil ? "无码/重连" : "配对码"))")
        do {
            let conn = try client.connect(endpoint: peer.endpoint, pin: .acceptAny)
            beginOutbound(conn, pairingCode: pairingCode)
        } catch {
            logger.log(.error, tool: "transfer", "出站连接创建失败: \(error.localizedDescription)")
            failState("连接失败: \(error.localizedDescription)")
        }
    }

    /// 主动连接(host/port 与 endpoint)共用的 post-`.ready` 装配:安装状态回调并记录 activeConn。
    private func beginOutbound(_ conn: TransferConnection, pairingCode: String?) {
        self.activeConn = conn
        conn.onStateChange = { [weak self, weak conn] st in
            guard let self, let conn else { return }
            switch st {
            case .ready:
                self.logger.log(.info, tool: "transfer", "出站:握手完成 .ready,读取对端指纹…")
                DispatchQueue.main.async { self.outboundReady(conn: conn, pairingCode: pairingCode) }
            case .waiting(let e):
                // 网络暂时不可达(对端未就绪 / 握手受阻等)。不改状态,交给 12s 超时裁决。
                self.logger.log(.warn, tool: "transfer", "出站:连接等待中(可能网络不可达或握手受阻): \(e)")
            case .failed(let e):
                self.logger.log(.warn, tool: "transfer", "出站:连接失败 \(e)")
                DispatchQueue.main.async { self.handleOutboundDrop(conn, failure: "连接失败: \(e)") }
            case .cancelled:
                DispatchQueue.main.async { self.handleOutboundDrop(conn, failure: nil) }
            default:
                // .setup / .preparing(TLS + WebSocket 握手中)。若一直停在 preparing 直到超时,
                // 说明对端回发的握手数据没到本端 —— 多半是网络只通单向(VPN/MTU/AP 隔离)。
                self.logger.log(.info, tool: "transfer", "出站连接状态: \(Self.describe(st))")
            }
        }
        armConnectTimeout(conn)
    }

    /// 把 NWConnection.State 转成可读字符串,供出站连接逐阶段日志使用。
    private static func describe(_ s: NWConnection.State) -> String {
        switch s {
        case .setup:            return "setup"
        case .waiting(let e):   return "waiting(\(e))"
        case .preparing:        return "preparing(TLS/WebSocket 握手中)"
        case .ready:            return "ready"
        case .failed(let e):    return "failed(\(e))"
        case .cancelled:        return "cancelled"
        @unknown default:       return "unknown"
        }
    }

    /// 出站连接 12s 未达 `.connected`/`.pairing`(仍 `.connecting`)则判超时取消。
    private func armConnectTimeout(_ conn: TransferConnection) {
        connectTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak conn] in
            guard let self else { return }
            if case .connecting = self.connectionState {
                conn?.cancel()
                self.logger.log(.warn, tool: "transfer", "出站:12s 内未完成握手(仍 .connecting)→ 判定连接超时。若对端已显示连接/配对成功,通常是网络只通单向(VPN / MTU / AP 隔离),导致对端回发的握手数据到不了本端。")
                self.failState("连接超时(握手未完成,可能是网络/VPN/MTU 问题)")
            } else if case .pairing = self.connectionState {
                // 配对中也设个上限
                conn?.cancel()
                self.logger.log(.warn, tool: "transfer", "出站:12s 内配对未完成(仍 .pairing)→ 判定配对超时。")
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
        // 配对中被对端断开:对端码不匹配/正忙/触发限速静默拒绝时,这条连接会被对端 cancel。
        // 不再干等 12s 超时,直接给可行动的失败原因。
        if case .pairing = connectionState {
            activeConn = nil
            connectionState = .failed(failure ?? "配对未完成:对端未响应(检查对端配对码是否一致,或稍候重试)")
            logger.log(.warn, tool: "transfer", "出站配对中连接被断开: \(failure ?? "对端无响应")")
            return
        }
        if let failure { failState(failure) }
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
        guard let fp = conn.peerFingerprint else {
            logger.log(.warn, tool: "transfer", "出站:.ready 但读不到对端证书指纹")
            failState("未取到对端证书"); return
        }
        logger.log(.info, tool: "transfer", "出站:已读到对端指纹 \(fp.prefix(8))…(\(pairingCode == nil ? "查已配对" : "开始配对"))")
        if pairingCode == nil {
            if let paired = peerStore.peer(forFingerprint: fp) {
                bindConnected(conn: conn, peer: paired)
            } else {
                activeConn?.cancel(); activeConn = nil
                failState("该设备未配对,请输入对端显示的配对码")
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
        logger.log(.info, tool: "transfer", "发起配对,对端 \(fp.prefix(8))…,输入码 \(pairingCode!)")
        startPairing(conn: conn, code: pairingCode!, peerFingerprint: fp)
    }

    // MARK: - 被动接受

    private func acceptInbound(_ conn: TransferConnection) {
        logger.log(.info, tool: "transfer", "① 收到入站连接,等待握手 .ready…")
        conn.onStateChange = { [weak self, weak conn] st in
            guard let self, let conn else { return }
            switch st {
            case .ready:
                self.logger.log(.info, tool: "transfer", "② 入站连接已 .ready,转入 inboundReady")
                DispatchQueue.main.async { self.inboundReady(conn: conn) }
            case .failed(let e):
                self.logger.log(.warn, tool: "transfer", "✗ 入站连接 .failed: \(e)")
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
        // 关键修复:强持有这条入站连接到 30s(覆盖握手 + 配对窗口)。否则 acceptInbound 一返回
        // 就无人强引用 conn —— 跨机网络延迟下,握手还没完成 conn 就被释放,.ready 落到已死的
        // wrapper(stateUpdateHandler 的 [weak self] 为 nil)→ inboundReady 永远不触发(本机环回
        // 握手极快才侥幸不复现)。绑定后由 activeConn 接管;到点仍未绑定则取消、随闭包一起释放。
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self else { return }
            if conn === self.activeConn { return }   // 已绑定,放过
            conn.cancel()
        }
    }

    private func inboundReady(conn: TransferConnection) {
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
        activeIsOutbound = false   // 此连接为被动入站:断开后不重连
        if let paired = peerStore.peer(forFingerprint: fp) {
            bindConnected(conn: conn, peer: paired)
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
            // 常驻码:失败不轮换,保持显示同一码,方便对端照着重试(防爆破已有冷却兜底)。
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
        autoReconnecting = false   // 已连上,本次(可能的)自动重连结束
        activeConn = conn
        activePeerFingerprint = peer.fingerprint
        // 记住这台,供前台/睡醒/重新发现时免码自动重连(出/入站都记,使两端断开后都能各自重连)。
        lastConnectedPeer = .init(deviceId: peer.deviceId, fingerprint: peer.fingerprint)
        // 已绑定 = 已配对:把「重试」改走免码重连(lastReconnect),避免重放已轮换失效的旧配对码
        // (否则首连后码已轮换,点重试会拿旧码重新配对而失败——正是用户最初抱怨的「码变了又要重配」)。
        if activeIsOutbound, lastReconnect != nil { lastManualConnect = lastReconnect }
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
        router.onData = { [weak self] msg in
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
            case .bye:
                DispatchQueue.main.async { self.handlePeerBye(peer: peer) }
            default:
                break
            }
        }
        conn.onMessage = { router.handle($0) }   // 强捕获 router:连接持有该闭包即维持其与内部 pm 存活
    }

    /// 对端主动断开(收到 .bye):尊重对端的「断开」意图,本机不再自动重连它。连接随后会被对端 cancel,
    /// 由 handleConnectedDrop 收尾回 idle;此处不强行 cancel,避免与收尾竞态。
    /// 两条自动重连路径都要堵死:
    ///   - 清 lastConnectedPeer → 挡住「发现即连」(maybeAutoReconnect);
    ///   - 清 wasConnected + 撞 reconnectGeneration → 挡住出站随之而来的 scheduleReconnect
    ///     (本机若是出站方,紧接着的断开本会触发 3 次重连,把刚被对方断开的会话又拉回来)。
    private func handlePeerBye(peer: PairedPeer) {
        if lastConnectedPeer?.deviceId == peer.deviceId { lastConnectedPeer = nil }
        wasConnected = false
        reconnectGeneration += 1
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
        peerStore.removeAll(); pairedPeers = []
        lastConnectedPeer = nil   // 配对全清:不再有可自动重连的对象
    }

    /// 置失败态。但若本次是「静默自动重连」(autoReconnecting),失败不打扰用户——清标志并回落 .idle
    /// (下次前台/发现/睡醒会再试),避免用户没点过的红色错误条凭空闪现。
    private func failState(_ msg: String) {
        if autoReconnecting {
            autoReconnecting = false
            connectionState = .idle
            // 失败即释放自动重连冷却:让随后刷新的发现/前台事件能立刻用重新解析的地址再试,
            // 不被冷却吞掉(冷却本意是挡密集触发,不该挡「上一发已失败」后的合法重试)。
            lastAutoReconnectAt = nil
            logger.log(.info, tool: "transfer", "自动重连未成功(静默回落空闲): \(msg)")
        } else {
            connectionState = .failed(msg)
        }
    }

    // MARK: - 自动(免码)重连

    /// 统一的自动重连入口:Bonjour 列表变化 / 切回前台 / 系统睡醒都会调用。
    /// 仅在「空闲 + 非用户主动断开 + 记得最后那台且它已配对并正被发现」时,免码重连最后那台。
    /// 决策本身是纯函数(TransferAutoReconnect.target),便于单测;这里只负责装配实参与节流。
    private func maybeAutoReconnect() {
        let busy: Bool
        switch connectionState {
        case .connected, .connecting, .pairing: busy = true
        case .idle, .failed:                     busy = false
        }
        // 让位给正在退避中的 scheduleReconnect(出站断线后的 2/4/8s 三次快速重连),避免两条重连路径互抢;
        // 三次用尽后 reconnectAttempts 停在 3,此时由本路径接管。
        if reconnectAttempts >= 1, reconnectAttempts < 3 { return }
        // 决策(含「本机 id 较小才主动拨号」的单向仲裁)收敛在纯函数里,便于单测。
        // 仲裁不可破例:睡醒那台若 id 较大,不在此自拨(会与对端的拨入撞成 glare 抖动),
        // 改由 onWokeOrActivated 的「自愈监听 + 重广播」让对端发现并拨入。
        guard let target = TransferAutoReconnect.target(
            busy: busy,
            userStopped: userStopped,
            selfDeviceId: identityStore.deviceId,
            last: lastConnectedPeer,
            discovered: discoveredPeers,
            pairedFingerprints: Set(pairedPeers.map(\.fingerprint))
        ) else { return }
        // 冷却:发现回调 / 前台事件可能密集触发,避免连成紧密循环(连接中/已连接时上面的 busy 已挡住)。
        // 注:auto 失败会在 failState 里清空冷却,允许随后刷新的发现用新地址即试,不被这 4s 吞掉。
        if let t = lastAutoReconnectAt, Date().timeIntervalSince(t) < 4 { return }
        lastAutoReconnectAt = Date()
        logger.log(.info, tool: "transfer", "自动重连(免码)→ \(target.name)")
        connect(to: target, pairingCode: nil, auto: true)   // auto:失败静默回落 .idle,不弹红条
    }

    /// 切回前台 / 系统睡醒:重启 Bonjour 浏览(睡眠后发现缓存可能失效),并尝试免码重连最后那台。
    /// 对端重新出现会再触发一次 onPeersChanged → maybeAutoReconnect,故这里直接调一次即可。
    private func onWokeOrActivated(_ reason: String) {
        guard let server else { return }
        // 已连接/连接中/配对中无需打扰(getFocus 会频繁触发 didBecomeActive,避免每次都重启浏览)。
        switch connectionState {
        case .connected, .connecting, .pairing: return
        case .idle, .failed: break
        }
        // 始终自愈监听,确保本机持续可被连入(睡眠/网络变更可能打死 listener;健康时为 no-op,无副作用)。
        // 这对「本机 id 较大」尤其关键:它不主动拨号(单向仲裁),全靠对端发现本机后拨入——前提是本机可被发现。
        server.restartIfUnhealthy()
        // 没有「最后那台」记忆 / 用户已主动停:仅维持可达性,不主动重连、也不重广播打扰对端。
        guard !userStopped, lastConnectedPeer != nil else { return }
        logger.log(.info, tool: "transfer", "\(reason):自愈监听/广播并尝试自动重连")
        // 「我回来了」重广播:提示对端尽快重新发现本机并拨入。仅在
        //   ① 没有正在退避的出站重连(reconnectAttempts==0)——退避中说明本端就是拨号方,再催对端会两边都拨成 glare;
        //   ② 距上次重广播 ≥5s(didBecomeActive 每次获焦都触发)——避免频繁重注册 Bonjour 致对端发现抖动
        // 时才发。
        if reconnectAttempts == 0,
           lastReassertAt == nil || Date().timeIntervalSince(lastReassertAt!) >= 5 {
            lastReassertAt = Date()
            server.setAdvertising(!stealthMode)
        }
        // 去抖:didBecomeActive 在每次窗口获焦都会触发,不必每次都 cancel+重建 NWBrowser。
        // 距上次刷新超过 3s 才重启浏览;其初始结果回调会再驱动一次 maybeAutoReconnect(用重新解析的 endpoint)。
        if lastDiscoveryRefreshAt == nil || Date().timeIntervalSince(lastDiscoveryRefreshAt!) >= 3 {
            lastDiscoveryRefreshAt = Date()
            discovery.start()    // 重新浏览,促使对端尽快重新出现
        }
        maybeAutoReconnect()
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
