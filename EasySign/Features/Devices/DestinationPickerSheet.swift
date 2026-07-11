import SwiftUI

// Modal sheet for picking a destination directory within the same AFC source
// (used by Copy / Move). Only shows folders — files in the current dir are
// filtered out for clarity. The user navigates by tapping folders and
// confirms with "选择此目录".
struct DestinationPickerSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    let source: SandboxBrowserView.Source
    let onSelect: (String?) -> Void   // nil = cancel

    @State private var currentPath: String = "/"
    @State private var folders: [FileNode] = []
    @State private var pathHistory: [String] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        GlassCanvas {
            VStack(spacing: GlassMetric.spacingM) {
                HStack {
                    GlassSectionTitle("选择目标文件夹", icon: "folder.badge.plus")
                    Spacer()
                }
                .glassSurface(.emphasized, radius: GlassMetric.radiusMedium, padding: GlassMetric.spacingM)

                // Toolbar — back + path
                HStack(spacing: GlassMetric.spacingS) {
                    BackButton(action: navigateBack, isDisabled: currentPath == "/")
                        .buttonStyle(GlassButtonStyle())
                    Text(currentPath)
                        .font(.caption)
                        .foregroundStyle(GlassPalette(colorScheme: colorScheme).mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .glassSurface(.inset, radius: GlassMetric.radiusMedium, padding: GlassMetric.spacingS)

                // Folder list
                content

                // Confirm bar
                HStack {
                    Text("当前选中：")
                        .font(.caption)
                        .foregroundStyle(GlassPalette(colorScheme: colorScheme).mutedText)
                    Text(currentPath)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button("取消") { onSelect(nil) }
                        .buttonStyle(GlassButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button("选择此目录") { onSelect(currentPath) }
                        .buttonStyle(GlassButtonStyle(.primary))
                        .keyboardShortcut(.defaultAction)
                }
                .glassSurface(.emphasized, radius: GlassMetric.radiusMedium, padding: GlassMetric.spacingM)
            }
            .padding(GlassMetric.spacingL)
        }
        .frame(width: 480, height: 440)
        .onAppear { load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ActivityCard(
                title: "正在读取文件夹",
                detail: "正在浏览 \(currentPath)",
                status: .active
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = errorMessage {
            ActivityCard(title: "无法读取目标文件夹", detail: error, status: .danger)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if folders.isEmpty {
            ActivityCard(
                title: "此目录下没有子文件夹",
                detail: "可以直接选择当前目录作为目标位置",
                status: .idle
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(folders) { node in
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(GlassPalette(colorScheme: colorScheme).primaryStart)
                    Text(node.name)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    pathHistory.append(currentPath)
                    currentPath = node.path
                    load()
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .listBottomContentMarginZero()
        }
    }

    private func navigateBack() {
        if !pathHistory.isEmpty {
            currentPath = pathHistory.removeLast()
        } else {
            currentPath = (currentPath as NSString).deletingLastPathComponent
            if currentPath.isEmpty { currentPath = "/" }
        }
        load()
    }

    private func load() {
        isLoading = true
        errorMessage = nil
        let snapshotSource = source
        let snapshotPath = currentPath

        DispatchQueue.global().async {
            do {
                let client: AFCClient
                switch snapshotSource {
                case .media(let device):
                    client = try DeviceService.shared.afcClient(for: device)
                case .appSandbox(let app):
                    client = try DeviceService.shared.afcClient(forApp: app)
                }
                let nodes = try client.listDirectory(at: snapshotPath)
                    .filter { $0.isDirectory }
                DispatchQueue.main.async {
                    folders = nodes
                    isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}
