import SwiftUI
import UniformTypeIdentifiers

struct SandboxBrowserView: View {
    @Environment(\.colorScheme) private var colorScheme
    enum Source: Equatable {
        case media(Device)
        case appSandbox(InstalledApp)
    }

    let source: Source
    let onFileSelected: (FileNode) -> Void
    let onNavigateBack: () -> Void

    // Browsing state
    @State private var currentPath: String = "/"
    @State private var fileNodes: [FileNode] = []
    @State private var isLoading: Bool = false
    // Fatal listing error — replaces the file list with an error screen.
    @State private var errorMessage: String?
    // Transfer (download/upload/copy/move/delete) failure — shown as an alert so
    // it does NOT blank out the browsed directory.
    @State private var transferError: String?
    @State private var afcClient: AFCClient?
    @State private var pathHistory: [String] = []

    // Selection — ⌘+click for multi-select.
    @State private var selectedIDs: Set<FileNode.ID> = []

    // Transfer state for the bottom progress bar.
    @State private var transferState: TransferState = .idle

    // Sheet state.
    @State private var destinationRequest: DestinationRequest?
    @State private var conflictRequest: ConflictRequest?
    @State private var deleteRequest: DeleteRequest?

    var body: some View {
        VStack(spacing: GlassMetric.spacingM) {
            if case .appSandbox(let app) = source {
                appContextHeader(app: app)
            }

            toolbar
            content
        }
        .padding(GlassMetric.spacingM)
        .glassSurface(.emphasized, radius: GlassMetric.radiusLarge)
        .onAppear { connectAndBrowse() }
        // 必须挂在最外层、不随 content 分支销毁的节点上:传输完成时
        // .succeeded 和紧随其后的 connectAndBrowse() 的 isLoading=true 会合并
        // 进同一次渲染,若 onChange 挂在 content 的 else 分支里,分支被 loading
        // 替换的那次更新收不到变化,自动消失永远不会被安排,成功条卡死。
        .autoDismissTransferSuccess($transferState)
        .onChange(of: source) { _, _ in
            currentPath = "/"
            pathHistory.removeAll()
            selectedIDs.removeAll()
            afcClient = nil
            connectAndBrowse()
        }
        .sheet(item: $destinationRequest) { req in
            DestinationPickerSheet(source: source) { picked in
                self.destinationRequest = nil
                guard let dest = picked else { return }
                switch req.kind {
                case .copy: performCopy(nodes: req.nodes, to: dest)
                case .move: performMove(nodes: req.nodes, to: dest)
                default: break
                }
            }
        }
        .sheet(item: $conflictRequest) { req in
            ConflictResolutionSheet(
                conflictingName: req.name,
                remainingCount: req.remaining,
                onResolve: req.resolve
            )
            // Force every exit (including Esc / click-away) through a button so
            // the background worker's semaphore is always signaled — otherwise a
            // non-button dismissal deadlocks the transfer thread forever.
            .interactiveDismissDisabled()
        }
        .alert(
            "传输失败",
            isPresented: Binding(
                get: { transferError != nil },
                set: { if !$0 { transferError = nil } }
            ),
            presenting: transferError
        ) { _ in
            Button("好", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
        .alert(
            "确认删除",
            isPresented: Binding(
                get: { deleteRequest != nil },
                set: { if !$0 { deleteRequest = nil } }
            ),
            presenting: deleteRequest
        ) { req in
            Button("删除", role: .destructive) {
                performDelete(nodes: req.nodes)
            }
            Button("取消", role: .cancel) {}
        } message: { req in
            Text(deleteConfirmMessage(for: req))
        }
    }

    private func deleteConfirmMessage(for req: DeleteRequest) -> String {
        let nodes = req.nodes
        if nodes.count == 1 {
            let node = nodes[0]
            if node.isDirectory {
                return "确定要删除文件夹 \"\(node.name)\" 及其全部内容吗？此操作无法撤销。"
            } else {
                return "确定要删除 \"\(node.name)\" 吗？此操作无法撤销。"
            }
        }
        return "确定要删除选中的 \(nodes.count) 个项目吗？此操作无法撤销。"
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            BackButton(action: navigateBack, isDisabled: !canNavigateBack)
                .buttonStyle(GlassButtonStyle())

            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(GlassIconButtonStyle())
            .disabled(transferState.isInProgress)

            Spacer()

            Text(currentPath)
                .font(.caption)
                .foregroundStyle(GlassPalette(colorScheme: colorScheme).mutedText)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button(action: promptUpload) {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.up.circle")
                    Text("上传").font(.caption)
                }
            }
            .buttonStyle(GlassButtonStyle(.primary))
            .disabled(transferState.isInProgress)
        }
        .glassSurface(.inset, radius: GlassMetric.radiusMedium, padding: GlassMetric.spacingS)
    }

    private var canNavigateBack: Bool {
        if currentPath != "/" { return true }
        switch source {
        case .media: return false
        case .appSandbox: return true
        }
    }

    @ViewBuilder
    private func appContextHeader(app: InstalledApp) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(GlassPalette(colorScheme: colorScheme).primaryGradient)
                .frame(width: 34, height: 34)
                .overlay(
                    Text(String(app.name.prefix(1)))
                        .font(.headline)
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(app.bundleID)
                    .font(.caption2)
                    .foregroundStyle(GlassPalette(colorScheme: colorScheme).mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .glassSurface(.inset, radius: GlassMetric.radiusMedium, padding: GlassMetric.spacingS)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ZStack {
            contentBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.glassState, value: contentStateKey)
    }

    /// 见 AppListView.contentStateKey:只在状态种类变化时转场。
    private var contentStateKey: String {
        if isLoading { return "loading" }
        if let error = errorMessage { return "error:\(error)" }
        return "list"
    }

    @ViewBuilder
    private var contentBody: some View {
        if isLoading {
            StatePlaceholder(
                title: "正在读取文件",
                detail: "正在浏览 \(currentPath)",
                status: .active
            )
            .transition(.glassState)
        } else if let error = errorMessage {
            StatePlaceholder(title: "无法读取当前目录", detail: error, status: .danger)
                .transition(.glassState)
        } else {
            // Mount the progress bar on the List via safeAreaInset(bottom:)
            // instead of stacking it next to the List in a VStack. Otherwise
            // the bottom row sits in the List's NSTableView bottom inset and
            // gets visually clipped + its hover/click hit-area swallowed by
            // the bar that pops in during transfers.
            List(fileNodes, selection: $selectedIDs) { node in
                FileNodeRow(node: node, isSelected: selectedIDs.contains(node.id))
                    .contentShape(Rectangle())
                    // onTapGesture(count: 2) is .gesture() internally and
                    // *replaces* default click handling. Despite that,
                    // List's NSTableView-backed selection still gets a
                    // chance at the click on macOS. simultaneousGesture
                    // didn't behave better here — it killed selection
                    // entirely.
                    .onTapGesture(count: 2) { handleNodeSelection(node) }
                    .contextMenu { contextMenu(for: node) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Drop the List's default bottom content margin so the very last
            // row's hit-area isn't swallowed.
            .listBottomContentMarginZero()
            // Accept files dragged from Finder. We filter out folders
            // because v1 doesn't support recursive upload.
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleFinderDrop(providers: providers)
                return true
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if transferState.isActive {
                    TransferProgressBar(state: transferState)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // 只对显隐(isActive)做隐式动画。不能 key 在 transferState 本身:
            // .inProgress 的 bytes 每 ~0.1s 变一次,会让整个 List 子树在传输
            // 期间持续重启 0.2s 动画(updateTransfer 刻意不带 withAnimation)。
            .animation(.easeInOut(duration: 0.2), value: transferState.isActive)
            .transition(.glassState)
        }
    }

    @ViewBuilder
    private func contextMenu(for node: FileNode) -> some View {
        let targets = effectiveTargets(for: node)
        Button("下载") { downloadNodes(targets) }
            .disabled(transferState.isInProgress)
        Divider()
        Button("复制到…") {
            destinationRequest = DestinationRequest(kind: .copy, nodes: targets)
        }
        .disabled(transferState.isInProgress)
        Button("移动到…") {
            destinationRequest = DestinationRequest(kind: .move, nodes: targets)
        }
        .disabled(transferState.isInProgress)
        Divider()
        Button("删除", role: .destructive) {
            deleteRequest = DeleteRequest(nodes: targets)
        }
        .disabled(transferState.isInProgress)
    }

    // If the user right-clicks an item that's part of the multi-selection, the
    // action covers the whole selection. Right-clicking an item NOT in the
    // selection acts on that item alone (matches Finder).
    private func effectiveTargets(for node: FileNode) -> [FileNode] {
        if selectedIDs.contains(node.id) && selectedIDs.count > 1 {
            return fileNodes.filter { selectedIDs.contains($0.id) }
        }
        return [node]
    }

    // MARK: - Browsing

    private func connectAndBrowse() {
        isLoading = true
        errorMessage = nil

        let capturedSource = source
        let capturedPath = currentPath

        DispatchQueue.global().async {
            do {
                let client = try makeClient(for: capturedSource)
                let nodes = try client.listDirectory(at: capturedPath)
                DispatchQueue.main.async {
                    self.afcClient = client
                    self.fileNodes = nodes
                    self.selectedIDs.removeAll()
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = friendlyErrorMessage(for: error, source: capturedSource)
                    self.isLoading = false
                }
            }
        }
    }

    private func makeClient(for source: Source) throws -> AFCClient {
        switch source {
        case .media(let device):
            return try DeviceService.shared.afcClient(for: device)
        case .appSandbox(let app):
            return try DeviceService.shared.afcClient(forApp: app)
        }
    }

    private func friendlyErrorMessage(for error: Error, source: Source) -> String {
        guard case .appSandbox = source, let hae = error as? HouseArrestError else {
            return error.localizedDescription
        }
        switch hae {
        case .startServiceFailed where hae.isTransient:
            return """
                house_arrest 服务暂时不可用。
                可能原因：刚刚做过 AFC 操作设备还在忙、或这个 App 在设备上从未启动过（容器尚未创建）。
                试试：在设备上手动打开一次这个 App，或稍等几秒重新选择。

                \(error.localizedDescription)
                """
        case .startServiceFailed:
            return """
                house_arrest 服务启动失败。

                \(error.localizedDescription)
                """
        case .rejected:
            return """
                此 App 没有授予沙盒访问权限。
                通常是 App Store 下载的 Distribution 包。
                你重签的 IPA 或 Dev / TestFlight 包可以正常浏览。

                \(error.localizedDescription)
                """
        default:
            return error.localizedDescription
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
        if currentPath == "/" {
            onNavigateBack()
            return
        }
        if !pathHistory.isEmpty {
            currentPath = pathHistory.removeLast()
        } else {
            currentPath = (currentPath as NSString).deletingLastPathComponent
            if currentPath.isEmpty { currentPath = "/" }
        }
        connectAndBrowse()
    }

    private func refresh() {
        connectAndBrowse()
    }

    // MARK: - Download

    private func downloadNodes(_ nodes: [FileNode]) {
        guard !transferState.isInProgress else { return }
        let files = nodes.filter { !$0.isDirectory }
        guard !files.isEmpty else {
            transferError = "暂不支持下载文件夹"
            return
        }

        // Single file → save panel lets user rename; multi → folder picker.
        if files.count == 1 {
            let node = files[0]
            let panel = NSSavePanel()
            panel.nameFieldStringValue = node.name
            guard panel.runModal() == .OK, let url = panel.url else { return }
            performDownload(files: [(node, url)])
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "选择下载目录"
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            let mapped = files.map { node -> (FileNode, URL) in
                (node, dir.appendingPathComponent(node.name))
            }
            performDownload(files: mapped)
        }
    }

    private func performDownload(files: [(FileNode, URL)]) {
        errorMessage = nil
        SandboxFileOperations.download(files: files, callbacks: transferCallbacks)
    }

    // MARK: - Upload

    private func promptUpload() {
        guard !transferState.isInProgress else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "上传"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        performUpload(localURLs: panel.urls)
    }

    private func handleFinderDrop(providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url, !url.hasDirectoryPath {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else {
                self.transferError = "拖入的内容不包含文件（v1 不支持文件夹）"
                return
            }
            self.performUpload(localURLs: urls)
        }
    }

    private func performUpload(localURLs: [URL]) {
        guard !transferState.isInProgress else { return }
        errorMessage = nil
        SandboxFileOperations.upload(localURLs: localURLs, destDir: currentPath, callbacks: transferCallbacks)
    }

    // MARK: - Copy / Move

    private func performCopy(nodes: [FileNode], to destDir: String) {
        let files = nodes.filter { !$0.isDirectory }
        guard !files.isEmpty else {
            transferError = "暂不支持复制文件夹（递归 copy 待实现）"
            return
        }
        runDeviceSideBatch(kind: .copy, nodes: files, destDir: destDir) { client, node, destPath, progress in
            try client.copyFile(from: node.path, to: destPath, progress: progress)
        }
    }

    private func performMove(nodes: [FileNode], to destDir: String) {
        runDeviceSideBatch(kind: .move, nodes: nodes, destDir: destDir) { client, node, destPath, _ in
            try client.move(from: node.path, to: destPath)
        }
    }

    // Copy/move 的共享入口:守卫后委托给 SandboxFileOperations.runBatch。
    private func runDeviceSideBatch(
        kind: TransferKind,
        nodes: [FileNode],
        destDir: String,
        operation: @escaping (AFCClient, FileNode, String,
                              ((UInt64, UInt64?) -> Void)?) throws -> Void
    ) {
        guard !transferState.isInProgress else { return }
        guard !nodes.isEmpty else { return }
        errorMessage = nil
        SandboxFileOperations.runBatch(kind: kind, nodes: nodes, destDir: destDir,
                                       operation: operation, callbacks: transferCallbacks)
    }

    // MARK: - Delete

    private func performDelete(nodes: [FileNode]) {
        guard !transferState.isInProgress else { return }
        guard !nodes.isEmpty else { return }
        errorMessage = nil
        SandboxFileOperations.delete(nodes: nodes, callbacks: transferCallbacks)
    }

    // MARK: - Conflict prompt bridge (background → main → background)

    // Blocks the calling (background) thread until the user dismisses the
    // sheet. Uses a semaphore to synchronize. If the user picks "应用于全部",
    // captures the choice in `remembered` so subsequent conflicts in this
    // batch skip the prompt.
    private func resolveConflictBlocking(
        name: String,
        remaining: Int,
        remembered: inout ConflictResolution?
    ) -> ConflictResolution {
        if let r = remembered { return r }

        let semaphore = DispatchSemaphore(value: 0)
        var pickedResolution: ConflictResolution = .cancel
        var pickedApplyAll: Bool = false

        DispatchQueue.main.async {
            self.conflictRequest = ConflictRequest(
                name: name,
                remaining: remaining,
                resolve: { r, all in
                    pickedResolution = r
                    pickedApplyAll = all
                    self.conflictRequest = nil
                    semaphore.signal()
                }
            )
        }
        semaphore.wait()

        if pickedApplyAll && pickedResolution != .cancel {
            remembered = pickedResolution
        }
        return pickedResolution
    }

    // MARK: - Transfer state helpers

    // 把 View 的 UI 交互(建 client / 进度 @State / 冲突 sheet / 刷新)打包给
    // SandboxFileOperations。闭包捕获 self(struct),@State 变更经其反射到共享存储,
    // 与原先在 View 内联 DispatchQueue.global 捕获 self 的值语义一致。
    private var transferCallbacks: SandboxTransferCallbacks {
        SandboxTransferCallbacks(
            makeClient: { try self.makeClient(for: self.source) },
            start: { kind, name, index, total in
                self.startTransfer(kind: kind, name: name, index: index, total: total)
            },
            update: { kind, name, index, total, bytes, total64 in
                self.updateTransfer(kind: kind, name: name, index: index, total: total, bytes: bytes, total64: total64)
            },
            complete: { kind, processed, firstName in
                self.completeTransfer(kind: kind, processed: processed, firstName: firstName)
            },
            fail: { error, file in
                self.failTransfer(error: error, file: file)
            },
            cancel: { self.cancelTransfer() },
            resolveConflict: { name, remaining, remembered in
                self.resolveConflictBlocking(name: name, remaining: remaining, remembered: &remembered)
            },
            reload: { DispatchQueue.main.async { self.connectAndBrowse() } }
        )
    }

    private func startTransfer(kind: TransferKind, name: String, index: Int, total: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            transferState = .inProgress(
                kind: kind, currentFile: name,
                currentIndex: index, totalFiles: total,
                bytes: 0, total: nil
            )
        }
    }

    private func updateTransfer(
        kind: TransferKind, name: String, index: Int, total: Int,
        bytes: UInt64, total64: UInt64?
    ) {
        DispatchQueue.main.async {
            let existingTotal: UInt64? = {
                if case .inProgress(_, _, _, _, _, let t) = self.transferState { return t }
                return nil
            }()
            self.transferState = .inProgress(
                kind: kind, currentFile: name,
                currentIndex: index, totalFiles: total,
                bytes: bytes, total: total64 ?? existingTotal
            )
        }
    }

    // Wraps up a batch: if nothing was actually processed (e.g. every file was
    // skipped at the conflict prompt), just dismiss the bar instead of falsely
    // reporting "完成".
    private func completeTransfer(kind: TransferKind, processed: Int, firstName: String) {
        if processed == 0 {
            cancelTransfer()
        } else {
            finishTransfer(kind: kind, summary: summary(processed, firstName))
        }
    }

    private func finishTransfer(kind: TransferKind, summary: String) {
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                self.transferState = .succeeded(kind: kind, summary: summary)
            }
        }
    }

    private func cancelTransfer() {
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                self.transferState = .idle
            }
        }
    }

    private func failTransfer(error: Error, file: String? = nil) {
        let detail = error.localizedDescription
        let message = file.map { "“\($0)”：\(detail)" } ?? detail
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                self.transferState = .idle
            }
            // Surface as an alert, not the full-screen error view, so the
            // current directory listing stays visible.
            self.transferError = message
        }
    }

    private func summary(_ count: Int, _ firstName: String) -> String {
        count == 1 ? firstName : "\(count) 个文件"
    }
}

// MARK: - Sheet request types

struct DestinationRequest: Identifiable {
    let id = UUID()
    let kind: TransferKind   // .copy or .move
    let nodes: [FileNode]
}

struct ConflictRequest: Identifiable {
    let id = UUID()
    let name: String
    let remaining: Int
    let resolve: (ConflictResolution, Bool) -> Void
}

struct DeleteRequest: Identifiable {
    let id = UUID()
    let nodes: [FileNode]
}

// MARK: - FileNodeRow

struct FileNodeRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let node: FileNode
    var isSelected: Bool = false

    var body: some View {
        HStack {
            Image(systemName: iconName(for: node))
                .foregroundStyle(iconColor(for: node, selected: isSelected))
                .frame(width: 24)

            Text(node.name)
                .lineLimit(1)

            Spacer()

            if !node.isDirectory {
                Text(formatSize(node.size))
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : GlassPalette(colorScheme: colorScheme).mutedText)
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
        case .video: return "film.fill"
        case .audio: return "waveform"
        case .database: return "cylinder.fill"
        default: return "doc.fill"
        }
    }

    private func iconColor(for node: FileNode, selected: Bool) -> Color {
        let palette = GlassPalette(colorScheme: colorScheme)
        // Selected rows get a blue accent background — colored icons
        // (blue folder, etc.) blend in. Switch to white on selection so
        // the icon stays visible.
        if selected { return .white }
        if node.isDirectory {
            return palette.primaryStart
        }
        switch node.fileType {
        case .text, .plist, .json: return .primary
        case .image: return palette.success
        case .video: return palette.primaryEnd
        case .audio: return palette.primaryStart
        case .database: return palette.warning
        default: return palette.mutedText
        }
    }

    private func formatSize(_ size: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}
