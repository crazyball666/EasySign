import Foundation

enum TransferPaths {
    /// ~/Library/Application Support/EasySign/Transfer/inbox
    static var inbox: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EasySign/Transfer/inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    static func uniqueInboxURL(for name: String) -> URL {
        // 只取最后一段文件名,剥离任何 ../ 或 / 路径分隔,防止越权写出 inbox
        let comp = (name as NSString).lastPathComponent
        let safe = (comp.isEmpty || comp == "." || comp == "..") ? "file" : comp
        var url = inbox.appendingPathComponent(safe)
        var i = 1
        let ext = (safe as NSString).pathExtension
        let stem = (safe as NSString).deletingPathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            let candidate = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            url = inbox.appendingPathComponent(candidate); i += 1
        }
        // 防御性兜底:解析后必须仍在 inbox 内
        if !url.standardizedFileURL.path.hasPrefix(inbox.standardizedFileURL.path) {
            return inbox.appendingPathComponent("file")
        }
        return url
    }
}
