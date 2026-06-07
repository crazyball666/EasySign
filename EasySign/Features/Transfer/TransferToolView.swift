import SwiftUI

struct TransferToolView: View {
    @ObservedObject var service: TransferService
    @State private var host = ""
    @State private var portText = ""
    @State private var codeInput = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard
                pairingCard
                connectCard
                syncCard
                historyCard
            }
            .padding(20)
        }
    }

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

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("连接到另一台", systemImage: "arrow.right.circle").font(.headline)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(.quaternary.opacity(0.4)).cornerRadius(10)
    }

    private var syncCard: some View {
        Toggle(isOn: $service.clipboardSyncEnabled) {
            Label("共享剪贴板(文本)", systemImage: "doc.on.clipboard")
        }
        .padding(12).background(.quaternary.opacity(0.4)).cornerRadius(10)
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("传输历史", systemImage: "clock.arrow.circlepath").font(.headline)
            if service.history.isEmpty {
                Text("暂无记录").foregroundStyle(.secondary)
            } else {
                ForEach(service.history) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.direction == .incoming ? "arrow.down.circle" : "arrow.up.circle")
                            .foregroundStyle(item.direction == .incoming ? .green : .blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.preview).lineLimit(2)
                            Text("\(item.peerName) · \(item.timestamp.formatted(date: .omitted, time: .standard))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if item.kind == PeerTransferKind.text {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.preview, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(.quaternary.opacity(0.4)).cornerRadius(10)
    }

    private var stateText: String {
        switch service.connectionState {
        case .idle: return "未连接"
        case .connecting: return "连接中…"
        case .pairing: return "配对中…"
        case let .connected(name): return "已连接:\(name)"
        case let .failed(msg): return "失败:\(msg)"
        }
    }
}
