//
//  Data.swift
//  EasySign
//
//  Created by crazyball on 2024/11/2.
//

import Foundation

extension Data {
    var hexString: String {
        self.map{ String(format: "%02x", $0)}.joined(separator: "")
    }
}

