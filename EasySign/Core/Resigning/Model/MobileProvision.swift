//
//  MobileProvision.swift
//  EasySign
//
//  Created by crazyball on 2024/10/31.
//

import Foundation

/// 描述文件
struct MobileProvision {
    let file: URL
    let name: String
    let uuid: String
    let teamId: String
    let createDate: Date?
    let expirationDate: Date?
    let applicationIdentifier: String
    let certs: [SecCertificate]
    let entitlements: [String: Any]
    let provisionedDevices: [String]?
    
    /// 获取本地已安装描述文件列表
    /// - Returns: 描述文件列表
    static func getInstalledMobileProvisions() -> [MobileProvision] {
        let fileManager = FileManager()
        guard let libraryDirectory = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first,
              let profileURLs = try? fileManager.contentsOfDirectory(at: libraryDirectory.appending(path: "MobileDevice/Provisioning Profiles"), includingPropertiesForKeys: nil, options: [])
        else {
            return []
        }
        let provisions = profileURLs.compactMap { url -> MobileProvision? in
            guard url.pathExtension == "mobileprovision", let provision = try? MobileProvision(file: url) else {
                return nil
            }
            return provision
        }
        return provisions.sorted(by: {
            $0.createDate?.timeIntervalSince1970 ?? 0 > $1.createDate?.timeIntervalSince1970 ?? 0
        })
    }
    
    
    init?(file: URL) throws {
        self.file = file
        let output = try TaskCenter.executeShell(command: "security cms -D -i \"\(file.path(percentEncoded: false))\"")
        guard let data = output.data(using: .utf8), let plist = try PropertyListSerialization.propertyList(from: data, options: .mutableContainers, format: nil) as? [String: Any] else {
            return nil
        }
        name = plist["Name"] as? String ?? ""
        uuid = plist["UUID"] as? String ?? ""
        teamId = (plist["TeamIdentifier"] as? [String])?.first ?? ""
        createDate = plist["CreationDate"] as? Date
        expirationDate = plist["ExpirationDate"] as? Date
        entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        let fullApplicationIdentifier = entitlements["application-identifier"] as? String ?? ""
        applicationIdentifier = fullApplicationIdentifier.replacingOccurrences(of: "\(teamId).", with: "")
        certs = (plist["DeveloperCertificates"] as? [Data] ?? []).compactMap { SecCertificate.create(data: $0) }
        provisionedDevices = plist["ProvisionedDevices"] as? [String] ?? []
    }
    
    func install() throws {
        let command = "open \"\(self.file)\""
        try TaskCenter.executeShell(command: command)
    }
}
