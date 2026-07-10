//
//  ThumbnailProvider.swift
//  EasySignThumbnail
//

import AppKit
import QuickLookThumbnailing

/// Finder 缩略图:.ipa 直接显示 App 真实图标(右下角 IPA 角标);
/// .mobileprovision 显示齿轮文档图 + 设备数胶囊(颜色按有效期红/橙/绿)。
final class ThumbnailProvider: QLThumbnailProvider {
    private enum ThumbnailError: Error {
        case unsupportedFileType
    }

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let url = request.fileURL
        let side = min(request.maximumSize.width, request.maximumSize.height)
        let size = NSSize(width: side, height: side)

        switch url.pathExtension.lowercased() {
        case "ipa", "zip":
            // 图标解码失败(如 Apple 优化过的 CgBI PNG)时回落到占位图
            let icon = (try? IPAPreviewService().preview(url: url, includeAppEntitlements: false))
                .flatMap { $0.iconData }
                .flatMap(NSImage.init(data:))
            let reply = QLThumbnailReply(contextSize: size) {
                Self.drawAppIcon(icon, size: size)
                return true
            }
            reply.extensionBadge = "IPA"
            handler(reply, nil)

        case "mobileprovision", "provisionprofile":
            let profile = try? IPAPreviewService().previewProvisioningProfileFile(url).profile
            let reply = QLThumbnailReply(contextSize: size) {
                Self.drawProfileIcon(profile, size: size)
                return true
            }
            reply.extensionBadge = "PROV"
            handler(reply, nil)

        default:
            handler(nil, ThumbnailError.unsupportedFileType)
        }
    }
}

private extension ThumbnailProvider {
    static func drawAppIcon(_ icon: NSImage?, size: NSSize) {
        let rect = NSRect(origin: .zero, size: size)
        // iOS 图标 PNG 是直角的,按 iOS 圆角比例裁一下
        let clipPath = NSBezierPath(
            roundedRect: rect,
            xRadius: size.width * 0.2237,
            yRadius: size.height * 0.2237
        )

        if let icon {
            NSGraphicsContext.current?.saveGraphicsState()
            clipPath.addClip()
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.current?.restoreGraphicsState()
        } else {
            drawPlaceholder(symbolName: "app.dashed", clipPath: clipPath, size: size)
        }
    }

    static func drawProfileIcon(_ profile: IPAPreviewProvisioningProfile?, size: NSSize) {
        let rect = NSRect(origin: .zero, size: size)
        let clipPath = NSBezierPath(
            roundedRect: rect.insetBy(dx: size.width * 0.05, dy: size.height * 0.05),
            xRadius: size.width * 0.08,
            yRadius: size.height * 0.08
        )
        drawPlaceholder(symbolName: "gearshape", clipPath: clipPath, size: size)

        guard let profile else {
            return
        }
        drawDeviceBadge(profile, size: size)
    }

    static func drawPlaceholder(symbolName: String, clipPath: NSBezierPath, size: NSSize) {
        NSColor.white.setFill()
        clipPath.fill()

        let config = NSImage.SymbolConfiguration(pointSize: size.width * 0.45, weight: .medium)
            .applying(.init(paletteColors: [.systemGray]))
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        else {
            return
        }
        let symbolSize = symbol.size
        symbol.draw(in: NSRect(
            x: (size.width - symbolSize.width) / 2,
            y: (size.height - symbolSize.height) / 2,
            width: symbolSize.width,
            height: symbolSize.height
        ))
    }

    static func drawDeviceBadge(_ profile: IPAPreviewProvisioningProfile, size: NSSize) {
        // 与预览界面的 ValidityStatus.uiColor 保持一致:未生效并入橙色警示,
        // 避免同一描述文件在 Finder 缩略图与 QuickLook 预览里显示不同颜色
        let tint: NSColor
        switch profile.validityStatus {
        case .valid:        tint = .systemGreen
        case .expiringSoon: tint = .systemOrange
        case .notYetValid:  tint = .systemOrange
        case .expired:      tint = .systemRed
        }

        let text = profile.provisionsAllDevices ? "∞" : "\(profile.provisionedDeviceCount)"
        let font = NSFont.boldSystemFont(ofSize: size.height * 0.16)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white
        ])
        let textSize = attributed.size()

        let badgeHeight = size.height * 0.24
        let badgeWidth = max(badgeHeight, textSize.width + badgeHeight * 0.6)
        // 放在右上角,略微内收,避免被 Finder 的圆角裁掉
        let badgeRect = NSRect(
            x: size.width - badgeWidth - size.width * 0.08,
            y: size.height - badgeHeight - size.height * 0.08,
            width: badgeWidth,
            height: badgeHeight
        )

        tint.setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: badgeHeight / 2, yRadius: badgeHeight / 2).fill()

        attributed.draw(at: NSPoint(
            x: badgeRect.midX - textSize.width / 2,
            y: badgeRect.midY - textSize.height / 2
        ))
    }
}
