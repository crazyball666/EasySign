//
//  PathManager.swift
//  EasySign
//
//  Created by crazyball on 2025/6/2.
//

import Foundation

struct PathManager {
    static func getCacheDir() throws -> URL {
        guard var cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "找不到 Caches 目录", code: -1, userInfo: nil)
        }
        cacheDir = cacheDir.appendingPathComponent(Bundle.main.bundleIdentifier ?? "ResignService")
        // 用 .path 而非 .absoluteString:absoluteString 是 file://… URL 串,fileExists 永远判 false。
        if !FileManager.default.fileExists(atPath: cacheDir.path) {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
        return cacheDir
    }

    /// 启动时清理重签遗留工作区(崩溃/强退时 ResignTask 的 defer 不会执行,
    /// 每次会留下数倍 IPA 大小的解压/归档残留)。删除 ResignTask/ 下早于 retentionDays 的目录。
    static func cleanupStaleResignWorkspaces(retentionDays: Int = 1) {
        guard let cacheDir = try? getCacheDir() else { return }
        let root = cacheDir.appendingPathComponent("ResignTask")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: [.contentModificationDateKey],
                                                        options: [.skipsHiddenFiles]) else { return }
        let cutoff = Date().addingTimeInterval(-Double(max(0, retentionDays)) * 86400)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fm.removeItem(at: entry)
            }
        }
    }
    
    static func getTempWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "ResignService")
            .appendingPathComponent(Date.now.formatString(format: "yyyyMMddHHmmssSSS"))
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }
}
