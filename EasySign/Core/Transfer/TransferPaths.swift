import Foundation

enum TransferPaths {
    /// ~/Library/Application Support/EasySign/Transfer/inbox
    static var inbox: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EasySign/Transfer/inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    /// 删除 dir 下「最后修改时间」早于 cutoff 的文件,返回删除的文件数。
    /// 抽成独立函数便于单测(对临时目录跑),并被 TransferService 的定时/启动清理复用。
    @discardableResult
    static func pruneFiles(in dir: URL, olderThan cutoff: Date) -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir,
                                                       includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return 0
        }
        var deleted = 0
        for f in files {
            guard let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { continue }
            if mtime < cutoff, (try? fm.removeItem(at: f)) != nil {
                deleted += 1
            }
        }
        return deleted
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
