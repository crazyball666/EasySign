//
//  ResignTaskInfo.swift
//  EasySign
//
//  Created by crazyball on 2025/6/2.
//

import Foundation


struct AppexResignInfo {
    var p12Path: URL
    var p12Password: String
    var mobileProvisionPath: URL
}

enum ResignExportType: String, CaseIterable {
    case appStore = "app-store"
    case dev = "development"
    case adHoc = "ad-hoc"
    case enterprise = "enterprise"
    case validation = "validation"
}

struct ResignTaskInfo {
    var filePath: URL
    var p12Path: URL
    var p12Password: String
    var mobileProvisionPath: URL
    var appexResignInfos: [String: AppexResignInfo]?
    var exportType: ResignExportType
    var outputPath: URL
    
    var bundleId: String?
    var displayName: String?
    var version: String?
    var buildVersion: String?
    var entitlements: String?
}
