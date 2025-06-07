//
//  SecIdentity.swift
//  EasySign
//
//  Created by crazyball on 2024/7/20.
//

import Foundation
import Security

extension SecIdentity {
    static func getAllInstalledIdentities() -> [SecIdentity] {
        let query = [
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnRef: true,
            kSecClass: kSecClassIdentity
        ] as CFDictionary
        var result: CFTypeRef?
        SecItemCopyMatching(query, &result)
        return result as? [SecIdentity] ?? []
    }
    
    var certificate: SecCertificate? {
        var cert: SecCertificate?
        SecIdentityCopyCertificate(self, &cert)
        return cert
    }
}
