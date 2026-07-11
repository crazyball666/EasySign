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
        GlassCanvas {
            GeometryReader { proxy in
                let usesInspector = GlassLayout.contextPresentation(for: proxy.size.width) == .inspector
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: GlassMetric.spacingL) {
                        workspaceHeader(showsInspector: usesInspector)
                        HStack(alignment: .top, spacing: GlassMetric.spacingL) {
                            qrCodeCanvas
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            if !usesInspector {
                                qrCodeContextRail.frame(width: 300)
                            }
                        }
                    }
                    .padding(GlassMetric.spacingXL)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Error", isPresented: Binding(value: $presentError)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(presentError?.localizedDescription ?? "")
        }
    }

    @ViewBuilder
    private func workspaceHeader(showsInspector: Bool) -> some View {
        WorkspaceHeader(
            icon: "qrcode",
            title: "二维码工作台",
            subtitle: "生成、分享与屏幕扫描",
            status: qrImage == nil ? .idle : .success,
            statusTitle: qrImage == nil ? "等待内容" : "已生成"
        ) {
            if showsInspector {
                GlassInspectorButton(title: "本次会话") {
                    ScrollView { qrCodeContextRail }
                }
            } else {
                EmptyView()
            }
        }
    }

    private var qrCodeCanvas: some View {
        VStack(alignment: .leading, spacing: GlassMetric.spacingL) {
            VStack(alignment: .leading, spacing: GlassMetric.spacingM) {
                ResignStageHeader(index: 1, title: "输入内容", detail: "内容仅用于本次生成，不会保存为历史记录")
                HStack(spacing: GlassMetric.spacingS) {
                    TextField("粘贴需要生成二维码的内容", text: $inputText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: inputText) { _, newValue in
                            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                qrImage = nil
                                statusText = ""
                            }
                        }
                    Button(action: generateQRCode) {
                        Label("生成二维码", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(GlassButtonStyle(.primary))
                }
                DropdownPickerRow(title: "图片尺寸", selection: $selectedSize, options: QRCodeCanvasSize.allCases, displayTitle: { $0.title })
            }
            .glassSurface(.standard, radius: GlassMetric.radiusLarge, padding: GlassMetric.spacingL)

            HStack(alignment: .center, spacing: GlassMetric.spacingXL) {
                qrPreview
                    .frame(width: 340, height: 340)
                VStack(alignment: .leading, spacing: GlassMetric.spacingS) {
                    actionButton("复制二维码", icon: "doc.on.doc", action: copyQRCode)
                    actionButton("保存二维码", icon: "square.and.arrow.down", action: saveQRCode)
                    actionButton("分享二维码", icon: "square.and.arrow.up", action: shareQRCode)
                    actionButton("AirDrop", icon: "antenna.radiowaves.left.and.right", action: airDropQRCode)
                    Divider().padding(.vertical, 3)
                    Button(action: scanScreen) {
                        Label("扫描屏幕上的二维码", systemImage: "viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassButtonStyle(.primary))
                }
                .frame(width: 220)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .glassSurface(.standard, radius: GlassMetric.radiusLarge, padding: GlassMetric.spacingXL)
        }
    }

    private var qrCodeContextRail: some View {
        ContextRail(title: "本次会话", subtitle: statusText.isEmpty ? "尚未执行操作" : statusText) {
            ResignSummaryRow(label: "图片尺寸", value: selectedSize.title, icon: "arrow.up.left.and.arrow.down.right")
            ResignSummaryRow(label: "扫描结果", value: scanResults.isEmpty ? "暂无" : "\(scanResults.count) 条", icon: "text.viewfinder")
            if !scanResults.isEmpty {
                VStack(alignment: .leading, spacing: GlassMetric.spacingS) {
                    GlassSectionTitle("扫描内容", icon: "list.bullet")
                    ForEach(Array(scanResults.enumerated()), id: \.offset) { index, value in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("第 \(index + 1) 个二维码")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(value)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                        .glassSurface(.inset, radius: GlassMetric.radiusSmall, padding: GlassMetric.spacingS)
                    }
                }
            }
        }
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(GlassButtonStyle())
        .disabled(qrImage == nil)
    }

    @ViewBuilder
    private var qrPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: qrcodePanelRadius, style: .continuous)
                .fill(.thinMaterial)

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
        .glassSurface(.inset, radius: GlassMetric.radiusLarge, padding: GlassMetric.spacingM)
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = GlassPalette(colorScheme: colorScheme)
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: qrcodePanelRadius, style: .continuous)
                    .fill(palette.primaryStart.opacity(0.14))
                Image(systemName: "qrcode")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(palette.primaryStart)
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
