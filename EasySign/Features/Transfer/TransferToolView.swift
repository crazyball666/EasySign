import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TransferToolView: View {
    @ObservedObject var service: TransferService
    @State private var host = ""
    @State private var portText = ""
    @State private var codeInput = ""          // 「连接到另一台」手动卡片用
    @State private var peerCodeInput = ""       // 发现设备行就地输码用(与上面解耦)
    @State private var localIP: String?         // 本机局域网 IP(展示用)
    @State private var isDropTargeted = false
    @State private var showClearHistoryConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard
                pairingCard
                discoveredCard
                connectCard
                sendFileCard
                syncCard
                if !service.activeTransfers.isEmpty {
                    activeTransfersCard
                }
                historyCard
                logCard
            }
            .padding(20)
        }
    }

    // MARK: - Log Card(排查用)

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("互传日志(排查用)", systemImage: "doc.plaintext").font(.headline)
            Text("配对失败后,点面板右上「复制全文」把日志发给开发者").font(.caption).foregroundStyle(.secondary)
            LogPanelView(logger: service.logger, toolId: "transfer")
                .frame(height: 240)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(.quaternary.opacity(0.4)).cornerRadius(10)
    }

    // MARK: - Status Card

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("本机", systemImage: "desktopcomputer").font(.headline)
            Text("设备名:\(service.deviceName)")
            if let ip = localIP {
                Text("本机 IP:\(ip)").textSelection(.enabled)
            }
            if let port = service.listenPort { Text("监听端口:\(String(port))") }
            HStack(spacing: 8) {
                Text(stateText).foregroundStyle(.secondary)
                Spacer()
                if case .connected = service.connectionState {
                    Button("断开") { service.disconnect() }
                        .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(.quaternary.opacity(0.4)).cornerRadius(10)
        .onAppear { localIP = LocalNetwork.lanIPv4() }
        .onChange(of: service.listenPort) { _ in localIP = LocalNetwork.lanIPv4() }
    }

    // MARK: - Pairing Card

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("本机配对码", systemImage: "key.fill").font(.headline)
            if let code = service.pendingPairingCode {
                Text(code)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                Text("想连接本机的设备,在它那边输入这个码").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("准备中…").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(.quaternary.opacity(0.4)).cornerRadius(10)
    }

    // MARK: - Discovered Peers Card

    private var discoveredCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("发现的设备", systemImage: "wifi").font(.headline)
            if service.discoveredPeers.isEmpty {
                Text("未发现设备（确保两台都在运行且同一网络）")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(service.discoveredPeers) { peer in
                    discoveredPeerRow(peer)
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(.quaternary.opacity(0.4)).cornerRadius(10)
    }

    private func discoveredPeerRow(_ peer: DiscoveredPeer) -> some View {
        let isPaired = service.pairedPeers.map(\.fingerprint).contains(peer.fingerprint)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(peer.name).fontWeight(.medium)
                Spacer()
                Text(isPaired ? "已配对" : "未配对")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isPaired ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                    .foregroundStyle(isPaired ? .green : .orange)
                    .cornerRadius(4)
                if isPaired {
                    Button("连接") { service.connect(to: peer, pairingCode: nil) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            // 未配对:就地填入「对方屏幕上显示的本机配对码」,带码连接(不再用无码探测去触发,杜绝竞态)。
            if !isPaired {
                HStack(spacing: 8) {
                    TextField("输入「\(peer.name)」屏幕上的配对码", text: $peerCodeInput)
                        .textFieldStyle(.roundedBorder)
                    Button("配对并连接") { service.connect(to: peer, pairingCode: peerCodeInput) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(peerCodeInput.count < 6)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Connect Card

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("连接到另一台", systemImage: "arrow.right.circle").font(.headline)
            HStack {
                TextField("对方 IP", text: $host).textFieldStyle(.roundedBorder)
                TextField("端口", text: $portText).frame(width: 80).textFieldStyle(.roundedBorder)
            }
            TextField("配对码（首次连接需要）", text: $codeInput).textFieldStyle(.roundedBorder)
            Button("连接") {
                guard let port = UInt16(portText) else { return }
                service.connect(host: host, port: port,
                                pairingCode: codeInput.isEmpty ? nil : codeInput)
            }
            .disabled(host.isEmpty || UInt16(portText) == nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(.quaternary.opacity(0.4)).cornerRadius(10)
    }

    // MARK: - Send File Card

    private var sendFileCard: some View {
        let isConnected: Bool
        if case .connected = service.connectionState { isConnected = true } else { isConnected = false }
        return VStack(alignment: .leading, spacing: 8) {
            Label("发送文件", systemImage: "arrow.up.doc").font(.headline)
            if !isConnected {
                Text("需先连接并配对")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                        style: StrokeStyle(lineWidth: 2, dash: [6])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                    )
                Text("拖文件到此发送")
                    .foregroundStyle(isConnected ? .primary : .secondary)
                    .padding(24)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
            .disabled(!isConnected)
            Button("发送文件…") {
                openFilePicker()
            }
            .disabled(!isConnected)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(.quaternary.opacity(0.4)).cornerRadius(10)
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

    // MARK: - Sync Card

    private var syncCard: some View {
        Toggle(isOn: $service.clipboardSyncEnabled) {
            Label("共享剪贴板（文本）", systemImage: "doc.on.clipboard")
        }
        .padding(12).background(.quaternary.opacity(0.4)).cornerRadius(10)
    }

    // MARK: - Active Transfers Card

    private var activeTransfersCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("进行中传输", systemImage: "arrow.up.arrow.down.circle").font(.headline)
            ForEach(service.activeTransfers) { p in
                activeTransferRow(p)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(.quaternary.opacity(0.4)).cornerRadius(10)
    }

    private func activeTransferRow(_ p: FileTransferManager.Progress) -> some View {
        let pct = p.total > 0 ? Int(Double(p.bytes) / Double(p.total) * 100) : 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: p.direction == .incoming ? "arrow.down.circle" : "arrow.up.circle")
                    .foregroundStyle(p.direction == .incoming ? .green : .blue)
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

    // MARK: - History Card

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("传输历史", systemImage: "clock.arrow.circlepath").font(.headline)
                Spacer()
                if !service.history.isEmpty {
                    Button("清理") { showClearHistoryConfirm = true }
                        .controlSize(.small)
                }
            }
            if service.history.isEmpty {
                Text("暂无记录").foregroundStyle(.secondary)
            } else if service.history.count > 6 {
                // 记录多时锁定高度,卡片内独立滚动,避免整页被撑得过长。
                ScrollView { historyList }.frame(height: 360)
            } else {
                historyList
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(.quaternary.opacity(0.4)).cornerRadius(10)
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
                .foregroundStyle(item.direction == .incoming ? .green : .blue)

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

    // MARK: - Helpers

    private var stateText: String {
        switch service.connectionState {
        case .idle: return "未连接"
        case .connecting: return "连接中…"
        case .pairing: return "配对中…"
        case let .connected(name): return "已连接：\(name)"
        case let .failed(msg): return "失败：\(msg)"
        }
    }
}
