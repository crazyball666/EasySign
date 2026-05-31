//
//  QRCodeService.swift
//  EasySign
//

import AppKit
import CoreImage
import Foundation

struct QRCodeScreenScanResult: Equatable {
    let codes: [String]
    let message: String
}

enum QRCodeServiceError: LocalizedError {
    case emptyText
    case cannotCreateQRCode
    case cannotRenderQRCode
    case cannotCreatePNG
    case cannotReadDisplays(CGError)

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "请输入需要生成二维码的内容"
        case .cannotCreateQRCode:
            return "二维码生成失败"
        case .cannotRenderQRCode:
            return "二维码渲染失败"
        case .cannotCreatePNG:
            return "二维码图片转换失败"
        case .cannotReadDisplays(let error):
            return "读取屏幕失败：\(error.rawValue)"
        }
    }
}

enum QRCodeService {
    static func makeQRCodeImage(text: String, size: CGSize) throws -> NSImage {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw QRCodeServiceError.emptyText
        }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw QRCodeServiceError.cannotCreateQRCode
        }

        filter.setDefaults()
        filter.setValue(Data(trimmedText.utf8), forKey: "inputMessage")
        filter.setValue("Q", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else {
            throw QRCodeServiceError.cannotCreateQRCode
        }

        let extent = outputImage.extent.integral
        let quietZoneRatio: CGFloat = 0.08
        let contentLength = min(size.width, size.height) * (1 - quietZoneRatio * 2)
        let scale = contentLength / max(extent.width, extent.height)
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let drawSize = scaledImage.extent.size
        let drawRect = NSRect(
            x: (size.width - drawSize.width) / 2,
            y: (size.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .none
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        scaledImage.draw(
            in: drawRect,
            from: scaledImage.extent,
            operation: .copy,
            fraction: 1
        )
        return image
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    static func scanQRCode(in image: CGImage) -> [String] {
        guard let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ) else {
            return []
        }

        let features = detector.features(in: CIImage(cgImage: image))
        var values: [String] = []
        for feature in features {
            guard let message = (feature as? CIQRCodeFeature)?.messageString,
                  !message.isEmpty,
                  !values.contains(message)
            else {
                continue
            }
            values.append(message)
        }
        return values
    }

    static func scanScreen() -> QRCodeScreenScanResult {
        let captureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("easysign-qrcode-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: captureURL) }

        do {
            try runProcess("/usr/sbin/screencapture", arguments: ["-x", "-t", "png", captureURL.path])
        } catch {
            return QRCodeScreenScanResult(codes: [], message: "截取屏幕失败，请确认已授权屏幕录制权限")
        }

        guard let image = NSImage(contentsOf: captureURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return QRCodeScreenScanResult(codes: [], message: "读取屏幕截图失败")
        }

        let codes = scanQRCode(in: cgImage)
        if codes.isEmpty {
            return QRCodeScreenScanResult(codes: [], message: "未识别到屏幕上的二维码，请确认已授权屏幕录制权限")
        }
        return QRCodeScreenScanResult(codes: codes, message: "识别到二维码个数：\(codes.count)")
    }

    private static func runProcess(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "QRCodeService", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "\(executable) failed with status \(process.terminationStatus)"
            ])
        }
    }
}
