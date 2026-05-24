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

    private var fileName: String {
        (path as NSString).lastPathComponent
    }

    var body: some View {
        // ZStack pinned to .bottom so the progress bar is its own anchored layer
        // regardless of the preview content's sizing. .overlay didn't work
        // reliably here because the inner VStack's intrinsic height depends on
        // what kind of preview is rendered.
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // 工具栏
                HStack {
                    BackButton(action: onBack)

                    Spacer()

                    Text(fileName)
                        .font(.headline)

                    Spacer()

                    Button("下载到本地") { downloadToLocal() }
                        .disabled(transferState.isInProgress)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.gray.opacity(0.1))

                Divider()

                // 预览内容
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage {
                    Text("Error: \(error)")
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let result = previewResult {
                    previewContent(result)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if transferState.isActive {
                TransferProgressBar(state: transferState)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear { loadPreview() }
        .autoDismissTransferSuccess($transferState)
    }

    @ViewBuilder
    private func previewContent(_ result: PreviewResult) -> some View {
        switch result {
        case .text(let content):
            ScrollView {
                Text(content)
                    .font(.system(.body, design: .monospaced))
                    .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .image(let nsImage):
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .database:
            VStack {
                Image(systemName: "cylinder")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("数据库预览暂未实现")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .binary(let data):
            ScrollView {
                Text(formatHex(data))
                    .font(.system(.caption, design: .monospaced))
                    .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .unsupported(let reason):
            VStack {
                Image(systemName: "doc.questionmark")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text(reason)
                    .foregroundColor(.secondary)
            }
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
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func makeClient(for source: SandboxBrowserView.Source) throws -> AFCClient {
        switch source {
        case .media(let device):
            return try AFCClient(device: device)
        case .appSandbox(let app):
            return try AFCClient(device: app.device, bundleID: app.bundleID)
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
