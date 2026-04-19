import SwiftUI

struct SandboxBrowserView: View {
    let app: InstalledApp?
    let initialPath: String
    let onFileSelected: (FileNode) -> Void
    let onNavigateBack: () -> Void

    @State private var currentPath: String = "/"
    @State private var fileNodes: [FileNode] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var afcClient: AFCClient?
    @State private var pathHistory: [String] = ["/"]

    var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            HStack {
                Button(action: navigateBack) {
                    Image(systemName: "chevron.left")
                }
                .disabled(currentPath == "/")

                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }

                Spacer()

                // 路径面包屑
                Text(currentPath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.gray.opacity(0.1))

            Divider()

            // 文件列表
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                Text("Error: \(error)")
                    .foregroundColor(.red)
            } else {
                List(fileNodes) { node in
                    FileNodeRow(node: node)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            handleNodeSelection(node)
                        }
                        .contextMenu {
                            Button("下载") { downloadFile(node) }
                            if !node.isDirectory {
                                Button("上传") { /* TODO */ }
                            }
                        }
                }
                .listStyle(.plain)
            }
        }
        .onAppear {
            currentPath = initialPath
            connectAndBrowse()
        }
    }

    private func connectAndBrowse() {
        guard let app = app else { return }

        isLoading = true
        errorMessage = nil

        DispatchQueue.global().async {
            do {
                let client = try AFCClient(device: app.device)
                let nodes = try client.listDirectory(at: currentPath)
                DispatchQueue.main.async {
                    self.afcClient = client
                    self.fileNodes = nodes
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func handleNodeSelection(_ node: FileNode) {
        if node.isDirectory {
            pathHistory.append(currentPath)
            currentPath = node.path
            connectAndBrowse()
        } else {
            onFileSelected(node)
        }
    }

    private func navigateBack() {
        guard !pathHistory.isEmpty else { return }
        currentPath = pathHistory.removeLast()
        connectAndBrowse()
    }

    private func refresh() {
        connectAndBrowse()
    }

    private func downloadFile(_ node: FileNode) {
        // 实现下载逻辑
    }
}

struct FileNodeRow: View {
    let node: FileNode

    var body: some View {
        HStack {
            Image(systemName: iconName(for: node))
                .foregroundColor(iconColor(for: node))
                .frame(width: 24)

            Text(node.name)
                .lineLimit(1)

            Spacer()

            if !node.isDirectory {
                Text(formatSize(node.size))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func iconName(for node: FileNode) -> String {
        if node.isDirectory {
            return "folder.fill"
        }
        switch node.fileType {
        case .text, .plist, .json: return "doc.text.fill"
        case .image: return "photo.fill"
        case .database: return "cylinder.fill"
        default: return "doc.fill"
        }
    }

    private func iconColor(for node: FileNode) -> Color {
        if node.isDirectory {
            return .blue
        }
        switch node.fileType {
        case .text, .plist, .json: return .primary
        case .image: return .green
        case .database: return .orange
        default: return .secondary
        }
    }

    private func formatSize(_ size: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}