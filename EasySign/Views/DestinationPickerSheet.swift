import SwiftUI

// Modal sheet for picking a destination directory within the same AFC source
// (used by Copy / Move). Only shows folders — files in the current dir are
// filtered out for clarity. The user navigates by tapping folders and
// confirms with "选择此目录".
struct DestinationPickerSheet: View {
    let source: SandboxBrowserView.Source
    let onSelect: (String?) -> Void   // nil = cancel

    @State private var currentPath: String = "/"
    @State private var folders: [FileNode] = []
    @State private var pathHistory: [String] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("选择目标文件夹")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Toolbar — back + path
            HStack(spacing: 6) {
                BackButton(action: navigateBack, isDisabled: currentPath == "/")
                Text(currentPath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.gray.opacity(0.06))

            Divider()

            // Folder list
            content

            Divider()

            // Confirm bar
            HStack {
                Text("当前选中：")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(currentPath)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button("取消") { onSelect(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("选择此目录") { onSelect(currentPath) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 480, height: 440)
        .onAppear { load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = errorMessage {
            Text(error)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if folders.isEmpty {
            Text("此目录下没有子文件夹")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(folders) { node in
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.blue)
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
                    client = try AFCClient(device: device)
                case .appSandbox(let app):
                    client = try AFCClient(device: app.device, bundleID: app.bundleID)
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
