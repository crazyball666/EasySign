import Foundation
#if canImport(AppKit)
import AppKit
#endif

enum PreviewResult {
    case text(String)
    // Holds the decoded NSImage so the view layer doesn't re-decode on every
    // body redraw (which was causing main-thread stutter during downloads).
    case image(NSImage)
    case database([[String: Any]])
    case binary(Data)
    case unsupported(reason: String)
}

final class FilePreviewer {
    // Caller uses this to decide how many bytes to fetch from AFC before calling
    // preview(). Text and images get a larger budget because partial reads of
    // big images can't be decoded at all (NSImage fails on truncated PNGs) and
    // large text logs are common.
    static let textImageLimit: UInt64 = 5 * 1024 * 1024  // 5MB
    static let defaultLimit: UInt64 = 2 * 1024 * 1024    // 2MB

    func maxBytesForPreview(fileName: String) -> UInt64 {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "txt", "log", "json", "xml", "plist", "yaml", "yml", "md", "sh",
             "swift", "m", "h", "c", "cpp", "hpp", "csv", "ini", "conf",
             "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp",
             "heic", "heif", "icns", "ico":
            return Self.textImageLimit
        default:
            return Self.defaultLimit
        }
    }

    func preview(data: Data, fileName: String) -> PreviewResult {
        let ext = (fileName as NSString).pathExtension.lowercased()

        switch ext {
        case "txt", "log", "json", "xml", "plist", "yaml", "yml", "md", "sh", "swift", "m", "h", "c", "cpp", "hpp", "csv", "ini", "conf":
            return previewText(data: data)

        // NSImage handles HEIC/HEIF natively on macOS 10.13+; iOS cameras default
        // to HEIC so it's worth covering.
        case "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "icns", "ico":
            return previewImage(data: data)

        case "db", "sqlite", "sqlite3":
            return previewDatabase(data: data)

        // Video / audio: not yet implemented. Would require AVPlayer plus a
        // full-file download path (current readFile only fetches 1MB).
        case "mov", "mp4", "m4v", "m4a", "aac", "wav", "mp3":
            return .unsupported(reason: "音视频预览暂未实现（需要下载完整文件后播放）")

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
        // Decode once here (called from the AFC background queue) and hand the
        // ready-to-render NSImage to the view. The previous implementation
        // round-tripped through PNG and let the view re-decode on every body
        // redraw, which pegged main during downloads.
        guard let image = NSImage(data: data) else {
            return .unsupported(reason: "无法加载图片")
        }
        return .image(image)
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
