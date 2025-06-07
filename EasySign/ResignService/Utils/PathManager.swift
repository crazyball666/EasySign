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
        if !FileManager.default.fileExists(atPath: cacheDir.absoluteString) {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
        return cacheDir
    }
    
    static func getTempWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "ResignService")
            .appendingPathComponent(Date.now.formatString(format: "yyyyMMddHHmmssSSS"))
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }
}
