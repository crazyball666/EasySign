//
//  PKCS12.swift
//  EasySign
//
//  Created by crazyball on 2025/6/2.
//

import Foundation

struct PKCS12 {
    let file: URL
    let password: String
    let identity: SecIdentity
    let certificate: SecCertificate
    
    init(file: URL, password: String) throws {
        self.file = file
        self.password = password
        
        let data = try Data(contentsOf: file)
        let options: [String: Any]
        if #available(macOS 15.0, *) {
            options = [
                kSecImportExportPassphrase as String: password,
                kSecImportToMemoryOnly as String: true
            ]
        } else {
            options = [kSecImportExportPassphrase as String: password]
        }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        
        guard status == errSecSuccess else {
            throw NSError(message: "读取 pkcs12 文件失败：\(status)")
        }
        
        guard let itemArray = items as Array? as? [[String: Any]], let identityDict = itemArray.first else {
            throw NSError(message: "提取 pkcs12 文件失败")
        }
        
        guard let identity = identityDict[kSecImportItemIdentity as String] as! SecIdentity? else {
            throw NSError(message: "解析 pkcs12 文件失败")
        }
        self.identity = identity

        // 获取证书
        var cert: SecCertificate?
        SecIdentityCopyCertificate(identity, &cert)
        guard let certificate = cert else {
            throw NSError(message: "读取 pkcs12 证书失败")
        }
        self.certificate = certificate
    }
}
