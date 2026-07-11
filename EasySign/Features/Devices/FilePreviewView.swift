import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct FilePreviewView: View {
    let source: SandboxBrowserView.Source
    let path: String
    let onBack: () -> Void

    @State private var previewResult: PreviewResult?
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    @State private var transferState: TransferState = .idle
    // Download failure shown as an alert so it doesn't blank out the preview.
    @State private var transferError: String?

    private var fileName: String {
        (path as NSString).lastPathComponent
    }

    var body: some View {
        // ZStack pinned to .bottom so the progress bar is its own anchored layer
        // regardless of the preview content's sizing. .overlay didn't work
        // reliably here because the inner VStack's intrinsic height depends on
        // what kind of preview is rendered.
        GlassCanvas {
            ZStack(alignment: .bottom) {
                VStack(spacing: GlassMetric.spacingM) {
                // 工具栏
                HStack {
                    BackButton(action: onBack)
                        .buttonStyle(GlassButtonStyle())

                    Spacer()

                    Text(fileName)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer()

                    Button("下载到本地") { downloadToLocal() }
                        .buttonStyle(GlassButtonStyle(.primary))
                        .disabled(transferState.isInProgress)
                }
                .glassSurface(.emphasized, radius: GlassMetric.radiusMedium, padding: GlassMetric.spacingM)

                // 预览内容
                if isLoading {
                    ActivityCard(
                        title: "正在加载预览",
                        detail: "正在从设备读取 \(fileName)",
                        status: .active
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage {
                    ActivityCard(title: "无法预览文件", detail: error, status: .danger)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let result = previewResult {
                    previewContent(result)
                }
                }
                .padding(GlassMetric.spacingL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if transferState.isActive {
                    TransferProgressBar(state: transferState)
                        .padding(.horizontal, GlassMetric.spacingL)
                        .padding(.bottom, GlassMetric.spacingL)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .onAppear { loadPreview() }
        .autoDismissTransferSuccess($transferState)
        .alert(
            "下载失败",
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
    }

    @ViewBuilder
    private func previewContent(_ result: PreviewResult) -> some View {
        switch result {
        case .text(let content):
            ScrollView {
                Text(content)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(GlassMetric.spacingM)
            }
            .glassSurface(.inset, radius: GlassMetric.radiusMedium)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .image(let nsImage):
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(GlassMetric.spacingM)
                .glassSurface(.inset, radius: GlassMetric.radiusMedium)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .database:
            ActivityCard(
                title: "数据库预览暂未实现",
                detail: "文件已读取，但当前不提供结构化数据库浏览",
                status: .idle
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .binary(let data):
            ScrollView {
                Text(formatHex(data))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(GlassMetric.spacingM)
            }
            .glassSurface(.inset, radius: GlassMetric.radiusMedium)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .unsupported(let reason):
            ActivityCard(title: "此文件暂不支持预览", detail: reason, status: .idle)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadPreview() {
        isLoading = true
        errorMessage = nil

        let capturedSource = source
        let capturedPath = path
        let capturedName = fileName
        let previewer = FilePreviewer()
        let maxBytes = previewer.maxBytesForPreview(fileName: capturedName)

        DispatchQueue.global().async {
            do {
                let client = try makeClient(for: capturedSource)
                let data = try client.readFile(at: capturedPath, maxBytes: maxBytes)
                let result = previewer.preview(data: data, fileName: capturedName)
                DispatchQueue.main.async {
                    self.previewResult = result
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

    private func downloadToLocal() {
        guard !transferState.isInProgress else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let capturedSource = source
        let capturedPath = path
        let capturedName = fileName

        withAnimation(.easeInOut(duration: 0.2)) {
            transferState = .inProgress(
                kind: .download, currentFile: capturedName,
                currentIndex: 1, totalFiles: 1,
                bytes: 0, total: nil
            )
        }
        errorMessage = nil

        DispatchQueue.global().async {
            let throttle = TransferProgressThrottle()
            do {
                let client = try makeClient(for: capturedSource)
                try client.streamFile(at: capturedPath, to: url) { written, total in
                    guard throttle.shouldFire(written: written, total: total) else { return }
                    DispatchQueue.main.async {
                        let existingTotal: UInt64? = {
                            if case .inProgress(_, _, _, _, _, let t) = self.transferState { return t }
                            return nil
                        }()
                        self.transferState = .inProgress(
                            kind: .download, currentFile: capturedName,
                            currentIndex: 1, totalFiles: 1,
                            bytes: written, total: total ?? existingTotal
                        )
                    }
                }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        self.transferState = .succeeded(kind: .download, summary: capturedName)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.transferState = .idle
                    }
                    self.transferError = error.localizedDescription
                }
            }
        }
    }

    private func makeClient(for source: SandboxBrowserView.Source) throws -> AFCClient {
        switch source {
        case .media(let device):
            return try DeviceService.shared.afcClient(for: device)
        case .appSandbox(let app):
            return try DeviceService.shared.afcClient(forApp: app)
        }
    }

    private func formatHex(_ data: Data) -> String {
        var result = ""
        let chunkSize = 16
        for offset in stride(from: 0, to: data.count, by: chunkSize) {
            let end = min(offset + chunkSize, data.count)
            let chunk = data[offset..<end]

            let hexPart = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let paddedHex = hexPart.padding(toLength: 47, withPad: " ", startingAt: 0)

            let asciiPart = String(chunk.map { byte -> Character in
                (32...126).contains(Int(byte)) ? Character(UnicodeScalar(byte)) : "."
            })

            result += String(format: "%08X  %@  %@\n", offset, paddedHex, asciiPart)
        }
        return result
    }
}
