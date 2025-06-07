//
//  BaseBundle.swift
//  EasySign
//
//  Created by crazyball on 2025/6/2.
//

import Foundation

class BaseBundle {
    private(set) var path: URL
    var infoDict: [String: Any]
    
    var bundleId: String {
        get {
            infoDict["CFBundleIdentifier"] as? String ?? ""
        }
        set {
            infoDict["CFBundleIdentifier"] = newValue
        }
    }
    
    var version: String {
        get {
            infoDict["CFBundleShortVersionString"] as? String ?? ""
        }
        set {
            infoDict["CFBundleShortVersionString"] = newValue
        }
    }
    
    var buildVersion: String {
        get {
            infoDict["CFBundleVersion"] as? String ?? ""
        }
        set {
            infoDict["CFBundleVersion"] = newValue
        }
    }
    
    init(path: URL) throws {
        self.path = path
        guard let infoDict = NSMutableDictionary(contentsOf: path.appendingPathComponent("Info.plist")) as? [String: Any] else {
            throw NSError.init(message: "读取失败 Info.plist")
        }
        self.infoDict = infoDict
    }
    
    func saveInfoPlist() throws {
        try (infoDict as NSDictionary).write(to: path.appendingPathComponent("Info.plist"))
    }
}
