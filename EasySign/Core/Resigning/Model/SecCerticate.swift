//
//  SecCerticate.swift
//  EasySign
//
//  Created by crazyball on 2024/7/20.
//

import Foundation
import CryptoSwift

extension SecCertificate {
    static func create(data: Data) -> SecCertificate? {
        return SecCertificateCreateWithData(kCFAllocatorDefault, data as CFData)
    }
    
    var commonName: String {
        var name: CFString?
        SecCertificateCopyCommonName(self, &name)
        return name as? String ?? ""
    }
    
    var certificateType: String {
        return commonName.components(separatedBy: ":").first ?? ""
    }
    
    var organization: String {
        return extractSubject(oid: kSecOIDOrganizationName)
    }
    
    var teamId: String {
        return extractSubject(oid: kSecOIDOrganizationalUnitName)
    }
    
    var countryName: String {
        return extractSubject(oid: kSecOIDCountryName)
    }
    
    var createDate: Date? {
        return extractDate(oid: kSecOIDX509V1ValidityNotBefore)
    }

    var expireDate:Date? {
        return extractDate(oid: kSecOIDX509V1ValidityNotAfter)
    }
    
    var sha1: Data {
        let der = SecCertificateCopyData(self) as Data
        return der.sha1()
    }

    var sha256: Data {
        let der = SecCertificateCopyData(self) as Data
        return der.sha256()
    }
    
    var description: String {
        commonName + " - SHA1: " + sha1.hexString
    }
}

private extension SecCertificate {
    func extractSubject(oid: CFString) -> String {
        var content = ""
        if let result = SecCertificateCopyValues(self, [kSecOIDX509V1SubjectName] as CFArray, nil) as? [CFString: [CFString: Any]],
           let subject = result[kSecOIDX509V1SubjectName],
           let subjectItems = subject[kSecPropertyKeyValue] as? [[CFString: CFString]]
        {
            subjectItems.forEach { item in
                if (item[kSecPropertyKeyLabel] == oid), let value = item[kSecPropertyKeyValue] {
                    content = value as NSString as String
                }
            }
        }
        return content
    }
    
    func extractDate(oid: CFString) -> Date? {
        guard let result = SecCertificateCopyValues(self, [oid] as CFArray, nil) as? [CFString: [CFString: Any]],
              let dict = result[oid],
              let dateInterval = dict[kSecPropertyKeyValue] as? NSNumber
        else {
            return nil
        }
        guard let sinceDate = DateComponents(calendar: Calendar.current, timeZone: TimeZone.gmt, year: 2001).date else {
            return nil
        }
        return Date(timeInterval: dateInterval.doubleValue, since: sinceDate)
    }
}
