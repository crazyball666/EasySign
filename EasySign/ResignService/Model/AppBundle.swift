//
//  AppBundle.swift
//  EasySign
//
//  Created by crazyball on 2025/6/2.
//

import Foundation

class AppBundle: BaseBundle {
    var appexList: [AppexBundle]!
    
    var displayName: String {
        get {
            infoDict["CFBundleDisplayName"] as? String ?? infoDict["CFBundleName"] as? String ?? ""
        }
        set {
            infoDict["CFBundleDisplayName"] = newValue
        }
    }
    
    var deviceFamily: [Int]? {
        return infoDict["UIDeviceFamily"] as? [Int]
    }
    
    var developmentRegion: String? {
        return infoDict["CFBundleDevelopmentRegion"] as? String
    }
    
    var dtPlatformVersion: String? {
        return infoDict["DTPlatformVersion"] as? String
    }
    
    var dtPlatformName: String? {
        return infoDict["DTPlatformName"] as? String
    }
    
    var dtSdkName: String? {
        return infoDict["DTSDKName"] as? String
    }
    
    var dtXcode: String? {
        return infoDict["DTXcode"] as? String
    }
    
    var minimumOSVersion: String? {
        return infoDict["MinimumOSVersion"] as? String
    }
    
    var iconName: String? {
        if let iconInfo = infoDict["CFBundleIcons"] as? [String: Any] ?? infoDict["CFBundleIcons~ipad"] as? [String: Any],
              let primaryIcon = iconInfo["CFBundlePrimaryIcon"] as? [String: Any]  {
            return primaryIcon["CFBundleIconName"] as? String
        }
        return nil
    }
    
    var executableName: String? {
        return infoDict["CFBundleExecutable"] as? String
    }
    
    var executableFilePath: URL? {
        if let executableName = executableName {
            return path.appendingPathComponent(executableName)
        }
        return nil
    }
    
    override init(path: URL) throws {
        try super.init(path: path)
        appexList = try getAppexBundleList()
    }
    
    func getEntitlementsString() throws -> String {
        guard let executableFilePath = self.executableFilePath,
              let result = MachOSignature.load(executableFilePath).first else {
            throw NSError(message: "读取 entitlements 失败")
        }
        return result.entitlements
    }
    
    func getEntitlements() throws -> [String: Any] {
        let entitlementsString = try getEntitlementsString()
        guard let data = entitlementsString.data(using: .utf8),
              let dict = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw NSError(message: "entitlements 格式异常")
        }
        return dict
    }
    
    /// 读取 Appex 列表
    /// - Parameter appPath: app 路径
    /// - Returns: appex 列表
    func getAppexBundleList() throws -> [AppexBundle] {
        let plugInsDir = path.appendingPathComponent("PlugIns")
        if FileManager.default.fileExists(atPath: plugInsDir.path) {
            return try FileManager.default.contentsOfDirectory(at: plugInsDir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles).compactMap { item -> AppexBundle? in
                guard item.pathExtension == "appex" else {
                    return nil
                }
                return try? AppexBundle(path: item)
            }
        }
        return []
    }
    
    func update(bundleId: String? = nil, displayName: String? = nil, version: String? = nil, buildVersion: String? = nil) throws {
        self.bundleId = bundleId ?? self.bundleId
        self.displayName = displayName ?? self.displayName
        self.version = version ?? self.version
        self.buildVersion = buildVersion ?? self.buildVersion
        try saveInfoPlist()
    }
}
