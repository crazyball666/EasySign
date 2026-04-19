import Foundation
#if canImport(AppKit)
import AppKit
#endif

enum PreviewResult {
    case text(String)
    case image(Data)
    case database([[String: Any]])
    case binary(Data)
    case unsupported(reason: String)
}

final class FilePreviewer {
    func preview(data: Data, fileName: String) -> PreviewResult {
        let ext = (fileName as NSString).pathExtension.lowercased()

        switch ext {
        case "txt", "log", "json", "xml", "plist", "yaml", "yml", "md", "sh", "swift", "m", "h", "c", "cpp", "hpp":
            return previewText(data: data)

        case "png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp":
            return previewImage(data: data)

        case "db", "sqlite", "sqlite3":
            return previewDatabase(data: data)

        case "txt", "log":
            return previewText(data: data)

        default:
            return previewBinary(data: data)
        }
    }

    private func previewText(data: Data) -> PreviewResult {
        guard let content = String(data: data, encoding: .utf8) else {
            return .unsupported(reason: "无法解析为文本文件")
        }
        return .text(content)
    }

    private func previewImage(data: Data) -> PreviewResult {
        #if canImport(AppKit)
        if let image = NSImage(data: data) {
            guard let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                return .unsupported(reason: "图片格式不支持")
            }
            return .image(pngData)
        }
        #endif
        return .unsupported(reason: "无法加载图片")
    }

    private func previewDatabase(data: Data) -> PreviewResult {
        // 使用 SQLite 解析数据库表
        // 这里简化处理，实际需要引入 SQLite 库或使用系统 SQLite3 API
        return .unsupported(reason: "数据库预览暂未实现")
    }

    private func previewBinary(data: Data) -> PreviewResult {
        // 显示前 1024 字节的十六进制和 ASCII
        let previewSize = min(1024, data.count)
        let previewData = data.prefix(previewSize)
        return .binary(Data(previewData))
    }
}
