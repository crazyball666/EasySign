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
        let safe = name.isEmpty ? "file" : name
        var url = inbox.appendingPathComponent(safe)
        var i = 1
        let ext = (safe as NSString).pathExtension
        let stem = (safe as NSString).deletingPathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            let candidate = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            url = inbox.appendingPathComponent(candidate); i += 1
        }
        return url
    }
}
