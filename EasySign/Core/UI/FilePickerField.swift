import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// 通用文件选择输入框：拖拽 / 点击选 / 清除 / 校验 / 最近使用下拉。
struct FilePickerField: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    @Binding var path: String
    let kind: RecentFileKind
    let allowedContentTypes: [UTType]
    let serviceHub: ServiceHub
    let validator: ((URL) -> String?)?

    @State private var error: String?
    @State private var isTargeted = false

    private var palette: GlassPalette { GlassPalette(colorScheme: colorScheme) }

    init(title: String,
         path: Binding<String>,
         kind: RecentFileKind,
         allowedContentTypes: [UTType],
         serviceHub: ServiceHub,
         validator: ((URL) -> String?)? = nil) {
        self.title = title
        self._path = path
        self.kind = kind
        self.allowedContentTypes = allowedContentTypes
        self.serviceHub = serviceHub
        self.validator = validator
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GlassMetric.spacingXS) {
            HStack(spacing: 6) {
                fileButton
                if !path.isEmpty { clearButton }
                recentsMenu
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(palette.danger)
                    .accessibilityLabel("文件校验失败：\(error)")
            }
        }
    }

    private var fileButton: some View {
        Button(action: pickFile) {
            HStack(spacing: 6) {
                Image(systemName: iconForKind)
                    .foregroundStyle(error == nil ? palette.mutedText : palette.danger)
                Text(displayText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(path.isEmpty ? palette.mutedText : Color.primary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(buttonBackground)
            .overlay(buttonBorder)
        }
        .buttonStyle(.plain)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
        .help(path.isEmpty ? title : path)
    }

    private var buttonBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(error == nil ? palette.insetFill : palette.danger.opacity(0.15))
    }

    private var buttonBorder: some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(borderColor, lineWidth: 1)
    }

    private var clearButton: some View {
        Button {
            path = ""
            error = nil
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(palette.mutedText)
        }
        .buttonStyle(.plain)
        .help("清除")
    }

    private var recentsMenu: some View {
        Menu {
            recentsContent
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(palette.mutedText)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 24)
        .help("最近使用")
    }

    @ViewBuilder
    private var recentsContent: some View {
        let recents = serviceHub.recent.all(kind: kind)
        if recents.isEmpty {
            Text("暂无最近使用").foregroundStyle(.secondary)
        } else {
            ForEach(recents.prefix(10)) { f in
                Button {
                    select(url: f.url)
                } label: {
                    HStack {
                        Text(f.url.lastPathComponent)
                        Spacer()
                        Text(relativeTime(f.lastUsed))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Button("清除最近") { serviceHub.recent.clear(kind: kind) }
        }
    }

    private var displayText: String {
        if !path.isEmpty { return URL(fileURLWithPath: path).lastPathComponent }
        return title
    }

    private var borderColor: Color {
        if isTargeted { return palette.primaryStart }
        if error != nil { return palette.danger }
        return palette.mutedBorder
    }

    private var iconForKind: String {
        switch kind {
        case .ipa: return "app.gift"
        case .p12: return "key.fill"
        case .mobileprovision: return "doc.badge.gearshape"
        case .other: return "doc"
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = allowedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            select(url: url)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url = url else { return }
            DispatchQueue.main.async { select(url: url) }
        }
        return true
    }

    private func select(url: URL) {
        // 检查扩展名
        let ext = url.pathExtension.lowercased()
        let extOK = allowedContentTypes.contains { $0.preferredFilenameExtension == ext }
            || (ext == "ipa" && allowedContentTypes.contains(where: { $0.conforms(to: .archive) }))
        if !extOK && !allowedContentTypes.isEmpty {
            error = "不支持：.\(ext)"
            return
        }
        path = url.path
        error = nil
        serviceHub.recent.record(url, kind: kind)
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.locale = Locale(identifier: "zh_CN")
        return f.localizedString(for: date, relativeTo: Date())
    }
}
