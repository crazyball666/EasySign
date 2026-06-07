import SwiftUI
import AppKit

/// 菜单栏(MenuBarExtra)内容:连接状态、剪贴板同步开关、待输入配对码、
/// 最近 5 条收发记录、打开主窗口、退出。常驻后台时也能查看与操作。
struct TransferMenuBar: View {
    @ObservedObject var service: TransferService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusText)
        Toggle("共享剪贴板(文本)", isOn: $service.clipboardSyncEnabled)
        if let code = service.pendingPairingCode {
            Divider()
            Text("配对码:\(code)")
        }
        Divider()
        if service.history.isEmpty {
            Text("暂无收发记录").foregroundStyle(.secondary)
        } else {
            ForEach(service.history.prefix(5)) { item in
                Text("\(item.direction == .incoming ? "↓" : "↑") \(preview(item))")
            }
        }
        Divider()
        Button("打开主窗口") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("退出 EasySign") { NSApp.terminate(nil) }
    }

    private func preview(_ item: TransferItem) -> String {
        let s = item.preview.replacingOccurrences(of: "\n", with: " ")
        return s.count > 40 ? String(s.prefix(40)) + "…" : s
    }

    private var statusText: String {
        switch service.connectionState {
        case .idle: return "互传:未连接"
        case .connecting: return "互传:连接中…"
        case .pairing: return "互传:配对中…"
        case let .connected(name): return "互传:已连接 \(name)"
        case let .failed(msg): return "互传:\(msg)"
        }
    }
}
