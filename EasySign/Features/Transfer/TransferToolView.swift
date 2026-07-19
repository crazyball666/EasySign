import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 互传主面板。状态驱动:顶部常驻一个醒目的连接状态条;未连接时只显示「怎么连」
/// (配对码 / 发现的设备 / 折叠的手动 IP),连上后只显示「传什么」(发送文件 / 剪贴板 / 进度);
/// 历史与排查日志收进底部折叠区。目的是去掉一长串同质卡片、让当前该做的事一眼可见。
struct TransferToolView: View {
    @ObservedObject var service: TransferService
    @Environment(\.colorScheme) private var colorScheme
    @State private var host = ""
    @State private var portText = ""
    @State private var codeInput = ""                       // 手动 IP 连接用
    @State private var peerCodeInputs: [String: String] = [:]   // 每个未配对设备各自独立(按指纹键),避免共用一个输入框
    @State private var localIP: String?                     // 本机局域网 IP(展示用)
    @State private var isDropTargeted = false
    @State private var showClearHistoryConfirm = false
    @State private var showManualConnect = false            // 手动 IP(默认折叠)
    @State private var showHistory = false                  // 传输历史(默认折叠)
    @State private var showLog = false                      // 排查日志(默认折叠)
    @StateObject private var networkPath = TransferNetworkPathObserver()

    private var palette: GlassPalette { GlassPalette(colorScheme: colorScheme) }

    private var isConnected: Bool {
        if case .connected = service.connectionState { return true }
        return false
    }

    var body: some View {
        GlassCanvas {
            GeometryReader { proxy in
                let usesInspector = GlassLayout.contextPresentation(for: proxy.size.width) == .inspector
                ScrollView {
                    VStack(alignment: .leading, spacing: GlassMetric.spacingL) {
                        transferHeader(showsInspector: usesInspector)
                        HStack(alignment: .top, spacing: GlassMetric.spacingL) {
                            VStack(alignment: .leading, spacing: GlassMetric.spacingL) {
                                statusHeader
                                if isConnected {
                                    connectedSection
                                } else {
                                    disconnectedSection
                                }
                                historyDisclosure
                                logDisclosure
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            if !usesInspector {
                                transferContextRail.frame(width: 290)
                            }
                        }
                    }
                    .glassWorkspacePadding()
                }
            }
        }
        .onAppear {
            localIP = LocalNetwork.lanIPv4()
            networkPath.start()
        }
        .onChange(of: service.listenPort) { _, _ in localIP = LocalNetwork.lanIPv4() }
        .onDisappear { networkPath.stop() }
    }

    @ViewBuilder
    private func transferHeader(showsInspector: Bool) -> some View {
        WorkspaceHeader(
            icon: "arrow.left.arrow.right",
            title: "互传会话",
            subtitle: isConnected ? "已连接，可传输文件与剪贴板" : "配对后可在局域网内安全互传",
            status: workspaceStatus,
            statusTitle: statusStyle.title
        ) {
            if showsInspector {
                GlassInspectorButton(title: "会话信息") {
                    ScrollView { transferContextRail }
                }
            } else {
                statusAction
            }
        }
    }

    private var transferContextRail: some View {
        ContextRail(title: "会话信息", subtitle: "当前连接与信任状态") {
            ResignSummaryRow(label: "本机", value: service.deviceName, icon: "laptopcomputer")
            ResignSummaryRow(label: "本机网络路径", value: networkPath.summary.title, icon: networkPath.summary.symbol)
            ResignSummaryRow(label: "本机地址", value: localIP ?? "正在检测", icon: "number")
            ResignSummaryRow(label: "端口", value: service.listenPort.map(String.init) ?? "未监听", icon: "point.3.connected.trianglepath.dotted")
            ResignSummaryRow(label: "信任设备", value: "\(service.pairedPeers.count) 台", icon: "checkmark.shield")
            ResignSummaryRow(label: "进行中", value: service.activeTransfers.isEmpty ? "无" : "\(service.activeTransfers.count) 项", icon: "arrow.up.arrow.down.circle")
            ActivityCard(title: statusStyle.title, detail: subtitle, status: workspaceStatus)
        }
    }

    private var workspaceStatus: GlassStatus {
        switch service.connectionState {
        case .connected: .success
        case .connecting, .pairing: .active
        case .failed: .danger
        case .idle: .idle
        }
    }

    // MARK: - 顶部状态条

    private var statusHeader: some View {
        let s = statusStyle
        let tint = palette.color(for: s.status)
        return HStack(alignment: .center, spacing: 12) {
            if s.spinner {
                ProgressView().controlSize(.small)
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: s.icon)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title)
                    .font(.headline)
                    .foregroundStyle(tint)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            statusAction
        }
        .padding(GlassMetric.spacingL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(.standard, radius: GlassMetric.radiusLarge, padding: 0)
    }

    @ViewBuilder
    private var statusAction: some View {
        switch service.connectionState {
        case .connected:
            Button("断开") { service.disconnect() }
                .buttonStyle(GlassButtonStyle())
                .controlSize(.large)
        case .failed:
            if service.canRetry {
                Button("重试") { service.retry() }
                    .buttonStyle(GlassButtonStyle(.primary))
                    .controlSize(.large)
            }
        default:
            EmptyView()
        }
    }

    /// 状态条的图标 / 配色 / 文案 / 是否转圈。
    private var statusStyle: (icon: String, status: GlassStatus, title: String, spinner: Bool) {
        switch service.connectionState {
        case .idle:                return ("wifi.slash", .idle, "未连接", false)
        case .connecting:          return ("", .active, "连接中…", true)
        case .pairing:             return ("", .active, "配对中…", true)
        case let .connected(name): return ("checkmark.circle.fill", .success, "已连接 · \(name)", false)
        case let .failed(msg):     return ("exclamationmark.triangle.fill", .danger, msg, false)
        }
    }

    private var subtitle: String {
        var parts = [service.deviceName]
        if let ip = localIP {
            parts.append(ip + (service.listenPort.map { ":\($0)" } ?? ""))
        } else if let port = service.listenPort {
            parts.append("端口 \(port)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 未连接:怎么连

    private var disconnectedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            pairingCard
            discoveredCard
            manualConnectDisclosure
        }
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("本机配对码", systemImage: "key.fill").font(.headline)
            if let code = service.pendingPairingCode {
                Text(code)
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                Text("想连接本机的设备,在它那边输入这个码").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("准备中…").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(.standard, radius: GlassMetric.radiusMedium, padding: 12)
    }

    private var discoveredCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("发现的设备", systemImage: "wifi").font(.headline)
            if service.discoveredPeers.isEmpty {
                Text("未发现设备(确保两台都在运行且同一网络)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(Array(service.discoveredPeers.enumerated()), id: \.element.id) { idx, peer in
                    discoveredPeerRow(peer)
                    if idx < service.discoveredPeers.count - 1 { Divider() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(.standard, radius: GlassMetric.radiusMedium, padding: 12)
    }

    private func discoveredPeerRow(_ peer: DiscoveredPeer) -> some View {
        let isPaired = service.pairedPeers.map(\.fingerprint).contains(peer.fingerprint)
        // 每台未配对设备绑定自己的输入框(按指纹键),不再共用一个 @State。
        let codeBinding = Binding(
            get: { peerCodeInputs[peer.fingerprint] ?? "" },
            set: { peerCodeInputs[peer.fingerprint] = $0 }
        )
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                Text(peer.name).fontWeight(.medium)
                Spacer()
                Text(isPaired ? "已配对" : "未配对")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isPaired ? palette.success.opacity(0.16) : palette.warning.opacity(0.16))
                    .foregroundStyle(isPaired ? palette.success : palette.warning)
                    .cornerRadius(4)
                if isPaired {
                    Button("连接") { service.connect(to: peer, pairingCode: nil) }
                        .buttonStyle(GlassButtonStyle(.primary))
                        .controlSize(.small)
                }
            }
            // 未配对:就地填入「对方屏幕上显示的本机配对码」,带码连接(杜绝无码探测竞态)。
            if !isPaired {
                HStack(spacing: 8) {
                    TextField("输入「\(peer.name)」屏幕上的配对码", text: codeBinding)
                        .textFieldStyle(.roundedBorder)
                    Button("配对并连接") { service.connect(to: peer, pairingCode: codeBinding.wrappedValue) }
                        .buttonStyle(GlassButtonStyle(.primary))
                        .controlSize(.small)
                        .disabled(codeBinding.wrappedValue.count < 6)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var manualConnectDisclosure: some View {
        DisclosureGroup(isExpanded: $showManualConnect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("对方 IP", text: $host).textFieldStyle(.roundedBorder)
                    TextField("端口", text: $portText).frame(width: 80).textFieldStyle(.roundedBorder)
                }
                TextField("配对码(首次连接需要)", text: $codeInput).textFieldStyle(.roundedBorder)
                Button("连接") {
                    guard let port = UInt16(portText) else { return }
                    service.connect(host: host, port: port,
                                    pairingCode: codeInput.isEmpty ? nil : codeInput)
                }
                .disabled(host.isEmpty || UInt16(portText) == nil)
            }
            .padding(.top, 6)
        } label: {
            Label("手动输入 IP 连接", systemImage: "arrow.right.circle").font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(.standard, radius: GlassMetric.radiusMedium, padding: 12)
    }

    // MARK: - 已连接:传什么

    private var connectedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sendFileCard
            syncCard
            if !service.activeTransfers.isEmpty {
                activeTransfersCard
            }
        }
    }

    private var sendFileCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("发送文件", systemImage: "arrow.up.doc").font(.headline)
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isDropTargeted ? palette.primaryStart : palette.mutedBorder,
                        style: StrokeStyle(lineWidth: 2, dash: [6])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isDropTargeted ? palette.primaryStart.opacity(0.08) : Color.clear)
                    )
                Text("拖文件到此发送").padding(24)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
            Button("发送文件…") { openFilePicker() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(.standard, radius: GlassMetric.radiusMedium, padding: 12)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { service.sendFile(url) } }
            }
        }
        return handled
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                service.sendFile(url)
            }
        }
    }

    private var syncCard: some View {
        Toggle(isOn: $service.clipboardSyncEnabled) {
            Label("共享剪贴板(文本)", systemImage: "doc.on.clipboard")
        }
        .glassSurface(.standard, radius: GlassMetric.radiusMedium, padding: 12)
    }

    private var activeTransfersCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: GlassMetric.spacingS) {
                ActivityPulse(isActive: true, color: palette.primaryStart)
                Label("进行中传输", systemImage: "arrow.up.arrow.down.circle").font(.headline)
            }
            ForEach(service.activeTransfers) { p in
                activeTransferRow(p)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(.standard, radius: GlassMetric.radiusMedium, padding: 12)
    }

    private func activeTransferRow(_ p: FileTransferManager.Progress) -> some View {
        let pct = p.total > 0 ? Int(Double(p.bytes) / Double(p.total) * 100) : 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: p.direction == .incoming ? "arrow.down.circle" : "arrow.up.circle")
                    .foregroundStyle(p.direction == .incoming ? palette.success : palette.primaryStart)
                Text(p.name).lineLimit(1)
                Spacer()
                Text("\(pct)%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(p.bytes), total: Double(max(p.total, 1)))
            Text("\(p.bytes) / \(p.total) 字节")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 折叠区:历史 / 日志

    private var historyDisclosure: some View {
        DisclosureGroup(isExpanded: $showHistory) {
            VStack(alignment: .leading, spacing: 8) {
                if service.history.isEmpty {
                    Text("暂无记录").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Button("清理历史和收到的文件") { showClearHistoryConfirm = true }
                        .controlSize(.small)
                    if service.history.count > 6 {
                        // 记录多时锁定高度,卡片内独立滚动,避免整页被撑得过长。
                        ScrollView { historyList }.frame(height: 360)
                    } else {
                        historyList
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Label("传输历史", systemImage: "clock.arrow.circlepath").font(.headline)
                if !service.history.isEmpty {
                    Text("\(service.history.count)")
                        .font(.caption2).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(palette.insetFill, in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(.inset, radius: GlassMetric.radiusMedium, padding: GlassMetric.spacingM)
        .confirmationDialog("清理传输历史?", isPresented: $showClearHistoryConfirm, titleVisibility: .visible) {
            Button("清理历史和收到的文件", role: .destructive) { service.clearHistory() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除全部历史记录,以及保存在本机 inbox 里收到的文件。不可撤销。")
        }
    }

    private var historyList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(service.history) { item in
                historyRow(item)
                Divider()
            }
        }
    }

    private func historyRow(_ item: TransferItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.direction == .incoming ? "arrow.down.circle" : "arrow.up.circle")
                .foregroundStyle(item.direction == .incoming ? palette.success : palette.primaryStart)

            historyRowContent(item)

            Spacer()
            historyRowActions(item)
        }
        .padding(.vertical, 4)
    }

    private func historyRowContent(_ item: TransferItem) -> some View {
        HStack(spacing: 6) {
            if item.kind == .image, let url = item.localURL,
               let nsImg = NSImage(contentsOf: url) {
                Image(nsImage: nsImg)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipped()
                    .cornerRadius(4)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview).lineLimit(2)
                Text("\(item.peerName) · \(item.timestamp.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func historyRowActions(_ item: TransferItem) -> some View {
        switch item.kind {
        case .text:
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.preview, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless)
            .help("复制文本")

        case .file:
            if let url = item.localURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.borderless)
                .help("打开")

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("在 Finder 显示")
            }

        case .image:
            if let url = item.localURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.borderless)
                .help("打开")

                Button {
                    if let img = NSImage(contentsOf: url) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([img])
                    }
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("复制图片")
            }
        }
    }

    private var logDisclosure: some View {
        DisclosureGroup(isExpanded: $showLog) {
            VStack(alignment: .leading, spacing: 6) {
                Text("连接/配对失败后,点面板右上「复制全文」把日志发给开发者").font(.caption).foregroundStyle(.secondary)
                LogPanelView(logger: service.logger, toolId: "transfer")
                    .frame(height: 240)
            }
            .padding(.top, 6)
        } label: {
            Label("排查日志", systemImage: "doc.plaintext").font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(.inset, radius: GlassMetric.radiusMedium, padding: GlassMetric.spacingM)
    }
}
