import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct FilePreviewView: View {
    let app: InstalledApp?
    let path: String
    let onBack: () -> Void

    @State private var previewResult: PreviewResult?
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var fileName: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            HStack {
                Button(action: onBack) {
                    HStack {
                        Image(systemName: "chevron.left")
                        Text("返回")
                    }
                }

                Spacer()

                Text(fileName)
                    .font(.headline)

                Spacer()

                Button("下载到本地") {
                    downloadToLocal()
                }
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
        .onAppear {
            loadPreview()
        }
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

        case .image(let data):
            if let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

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
        guard let app = app else { return }

        isLoading = true
        errorMessage = nil
        fileName = (path as NSString).lastPathComponent

        DispatchQueue.global().async {
            do {
                let client = try AFCClient(device: app.device)
                let data = try client.readFile(at: path)

                let previewer = FilePreviewer()
                let result = previewer.preview(data: data, fileName: fileName)

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
        guard let app = app else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName

        if panel.runModal() == .OK, let url = panel.url {
            DispatchQueue.global().async {
                do {
                    let client = try AFCClient(device: app.device)
                    let data = try client.readFile(at: path)
                    try data.write(to: url)
                } catch {
                    DispatchQueue.main.async {
                        // 显示错误
                    }
                }
            }
        }
    }

    private func formatHex(_ data: Data) -> String {
        var result = ""
        let chunkSize = 16
        for offset in stride(from: 0, to: data.count, by: chunkSize) {
            let end = min(offset + chunkSize, data.count)
            let chunk = data[offset..<end]

            // Hex part
            let hexPart = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let paddedHex = hexPart.padding(toLength: 47, withPad: " ", startingAt: 0)

            // ASCII part
            let asciiPart = String(chunk.map { byte -> Character in
                (32...126).contains(Int(byte)) ? Character(UnicodeScalar(byte)) : "."
            })

            result += String(format: "%08X  %@  %@\n", offset, paddedHex, asciiPart)
        }
        return result
    }
}
