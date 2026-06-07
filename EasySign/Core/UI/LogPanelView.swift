import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 升级版日志面板：级别彩色 / 过滤 / 复制 / 保存到文件 / 切换 run。
public struct LogPanelView: View {
    @ObservedObject var logger: LoggerService
    let toolId: String
    @State private var minLevel: LogLevel = .debug
    @State private var filter: String = ""
    // LoggerService 的 buffer 不是 @Published,光观察 logger 不会在新日志到达时重绘;
    // 用定时器周期性 bump 强制重新读取 recentEntries,保证日志实时显示。
    @State private var refreshTick = 0
    private let refreshTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    public init(logger: LoggerService, toolId: String) {
        self.logger = logger
        self.toolId = toolId
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(filteredEntries) { entry in
                        LogRow(entry: entry)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                    }
                }
                .padding(.vertical, 4)
                .id(refreshTick)   // tick 变化即强制重读 filteredEntries
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .onReceive(refreshTimer) { _ in refreshTick &+= 1 }
    }

    private var filteredEntries: [LogEntry] {
        let byTool = logger.recentEntries.filter { toolId.isEmpty || $0.tool == toolId }
        let byLevel = byTool.filter { $0.level >= minLevel }
        guard !filter.isEmpty else { return byLevel }
        let q = filter.lowercased()
        return byLevel.filter {
            $0.message.lowercased().contains(q) || $0.category.lowercased().contains(q)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Picker("级别", selection: $minLevel) {
                Text("Debug").tag(LogLevel.debug)
                Text("Info").tag(LogLevel.info)
                Text("Warn").tag(LogLevel.warn)
                Text("Error").tag(LogLevel.error)
            }
            .pickerStyle(.menu)
            .frame(width: 100)

            TextField("搜索", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)

            Spacer()

            Text("\(filteredEntries.count) 条")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button("复制全文") { copyAll() }
                .buttonStyle(.borderless)
            Button("保存") { saveToFile() }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func copyAll() {
        let text = filteredEntries.map { entry in
            let f = ISO8601DateFormatter()
            return "[\(f.string(from: entry.timestamp))][\(entry.level.rawValue.uppercased())] \(entry.message)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.log, .plainText]
        panel.nameFieldStringValue = "\(toolId)-\(Int(Date().timeIntervalSince1970)).log"
        if panel.runModal() == .OK, let url = panel.url {
            let text = filteredEntries.map { entry in
                let f = ISO8601DateFormatter()
                return "[\(f.string(from: entry.timestamp))][\(entry.level.rawValue.uppercased())] \(entry.message)"
            }.joined(separator: "\n")
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(timeString(entry.timestamp))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("[\(entry.level.rawValue.uppercased())]")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(colorForLevel)
                .frame(width: 50, alignment: .leading)
            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private var colorForLevel: Color {
        switch entry.level {
        case .debug: return .secondary
        case .info:  return .primary
        case .warn:  return .orange
        case .error: return .red
        }
    }

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}
