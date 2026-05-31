//
//  QRCodeToolView.swift
//  EasySign
//

import SwiftUI
import UniformTypeIdentifiers

private let qrcodePanelRadius: CGFloat = 8

struct QRCodeToolView: View {
    @State private var inputText = ""
    @State private var selectedSize: QRCodeCanvasSize = .large
    @State private var qrImage: NSImage?
    @State private var statusText = ""
    @State private var scanResults: [String] = []
    @State private var presentError: Error?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                QRCodePageHeader()

                ResignSectionView(title: "二维码内容", systemImage: "qrcode") {
                    HStack(spacing: 10) {
                        TextField("粘贴需要生成二维码的内容", text: $inputText)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: inputText) { newValue in
                                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    qrImage = nil
                                    statusText = ""
                                }
                            }

                        Button(action: generateQRCode) {
                            Label("生成二维码", systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    DropdownPickerRow(
                        title: "图片尺寸",
                        selection: $selectedSize,
                        options: QRCodeCanvasSize.allCases,
                        displayTitle: { $0.title }
                    )
                }

                ResignSectionView(title: "二维码预览", systemImage: "square.on.square") {
                    HStack(alignment: .top, spacing: 18) {
                        qrPreview
                            .frame(width: 320, height: 320)

                        VStack(alignment: .leading, spacing: 10) {
                            Button(action: copyQRCode) {
                                Label("复制二维码", systemImage: "doc.on.doc")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(qrImage == nil)

                            Button(action: saveQRCode) {
                                Label("保存二维码", systemImage: "square.and.arrow.down")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(qrImage == nil)

                            Button(action: shareQRCode) {
                                Label("分享二维码", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(qrImage == nil)

                            Button(action: airDropQRCode) {
                                Label("AirDrop", systemImage: "antenna.radiowaves.left.and.right")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(qrImage == nil)

                            Button(action: scanScreen) {
                                Label("扫描屏幕上的二维码", systemImage: "viewfinder")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            if !statusText.isEmpty {
                                Text(statusText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .padding(.top, 4)
                            }
                        }
                        .frame(width: 210)
                    }
                }

                if !scanResults.isEmpty {
                    ResignSectionView(title: "扫描结果", systemImage: "text.viewfinder") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(scanResults.enumerated()), id: \.offset) { index, value in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("第 \(index + 1) 个二维码")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(value)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.primary.opacity(0.04))
                                )
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Error", isPresented: Binding(value: $presentError)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(presentError?.localizedDescription ?? "")
        }
    }

    @ViewBuilder
    private var qrPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: qrcodePanelRadius, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: qrcodePanelRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.08))
                )

            if let qrImage {
                Image(nsImage: qrImage)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .padding(14)
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 96, weight: .regular))
                    .foregroundStyle(Color.secondary.opacity(0.35))
            }
        }
    }

    private func generateQRCode() {
        do {
            qrImage = try QRCodeService.makeQRCodeImage(text: inputText, size: selectedSize.cgSize)
            scanResults = []
            statusText = "二维码生成成功"
        } catch {
            presentError = error
        }
    }

    private func copyQRCode() {
        guard let image = qrImage else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.writeObjects([image]) {
            statusText = "二维码已复制到剪贴板"
        } else {
            statusText = "复制二维码失败"
        }
    }

    private func saveQRCode() {
        guard let image = qrImage else {
            return
        }
        guard let pngData = QRCodeService.pngData(from: image) else {
            presentError = QRCodeServiceError.cannotCreatePNG
            return
        }

        let panel = NSSavePanel()
        panel.title = "保存二维码"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.png]
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultImageName()
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try pngData.write(to: url)
                statusText = "二维码已保存到 \(url.path)"
            } catch {
                presentError = error
            }
        }
    }

    private func shareQRCode() {
        guard let image = qrImage,
              let contentView = NSApp.keyWindow?.contentView
        else {
            return
        }
        NSSharingServicePicker(items: [image])
            .show(relativeTo: .zero, of: contentView, preferredEdge: .maxY)
    }

    private func airDropQRCode() {
        guard let image = qrImage else {
            return
        }
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: [image]) else {
            statusText = "当前不可使用 AirDrop"
            return
        }
        service.perform(withItems: [image])
    }

    private func scanScreen() {
        let result = QRCodeService.scanScreen()
        scanResults = result.codes
        statusText = result.message
    }

    private func defaultImageName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH-mm-ss"
        return "EasySign_qrcode-\(formatter.string(from: Date())).png"
    }
}

private struct QRCodePageHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: qrcodePanelRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                Image(systemName: "qrcode")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("二维码工具")
                    .font(.title2.weight(.semibold))
                Text("QRCode")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.bottom, 2)
    }
}

private enum QRCodeCanvasSize: Int, CaseIterable, Hashable {
    case small = 300
    case medium = 680
    case large = 1024
    case huge = 1680

    var title: String {
        "\(rawValue)x\(rawValue)"
    }

    var cgSize: CGSize {
        CGSize(width: rawValue, height: rawValue)
    }
}
