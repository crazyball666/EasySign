//
//  ResignTaskInfo.swift
//  EasySign
//
//  Created by crazyball on 2025/6/2.
//

import Foundation

enum ResignExportType: String, CaseIterable {
    case appStore = "app-store"
    case dev = "development"
    case adHoc = "ad-hoc"
    case enterprise = "enterprise"
    case validation = "validation"
}

enum ResignBackend: String, CaseIterable {
    case zsign = "zsign"
    case apple = "codesign"

    var displayName: String {
        switch self {
        case .zsign:
            return "zsign"
        case .apple:
            return "codesign"
        }
    }

    /// 这条后端要跑 `xcodebuild -exportArchive`,只装命令行工具时会失败。
    /// 详见 XcodeAvailability。
    var requiresFullXcode: Bool { self == .apple }
}

struct ResignTaskInfo {
    var filePath: URL
    var p12Path: URL
    var p12Password: String
    var mobileProvisionPath: URL
    var exportType: ResignExportType
    var backend: ResignBackend
    var injectedDylibPaths: [URL]
    var outputPath: URL
    
    var bundleId: String?
    var displayName: String?
    var version: String?
    var buildVersion: String?
    var entitlements: String?
}
