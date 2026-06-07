import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TransferToolView: View {
    @ObservedObject var service: TransferService
    @State private var host = ""
    @State private var portText = ""
    @State private var codeInput = ""
    @State private var isDropTargeted = false

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
            }
            .padding(20)
        }
    }

    // MARK: - Status Card

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("本机", systemImage: "desktopcomputer").font(.headline)
            Text("设备名:\(service.deviceName)")
            if let port = service.listenPort { Text("监听端口:\(String(port))") }
            Text(stateText).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(.quaternary.opacity(0.4)).cornerRadius(10)
    }

    // MARK: - Pairing Card

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("配对码", systemImage: "key.fill").font(.headline)
            if let code = service.pendingPairingCode {
                Text(code).font(.system(size: 28, weight: .bold, design: .monospaced))
                Text("在另一台输入此码以配对").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("等待对端连接时显示").foregroundStyle(.secondary)
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
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name).fontWeight(.medium)
                if !isPaired {
                    Text("未配对设备需填对方配对码")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(isPaired ? "已配对" : "未配对")
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isPaired ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                .foregroundStyle(isPaired ? .green : .orange)
                .cornerRadius(4)
            Button("连接") {
                if isPaired {
                    service.connect(to: peer, pairingCode: nil)
                } else {
                    service.connect(to: peer, pairingCode: codeInput.isEmpty ? nil : codeInput)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
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
            Label("传输历史", systemImage: "clock.arrow.circlepath").font(.headline)
            if service.history.isEmpty {
                Text("暂无记录").foregroundStyle(.secondary)
            } else {
                ForEach(service.history) { item in
                    historyRow(item)
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(.quaternary.opacity(0.4)).cornerRadius(10)
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
