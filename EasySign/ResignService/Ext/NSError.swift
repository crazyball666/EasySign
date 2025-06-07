//
//  NSError.swift
//  EasySign
//
//  Created by crazyball on 2024/7/21.
//

import Foundation

extension NSError {
    convenience init(message: String, code: Int = -1) {
        self.init(domain: "com.EasySign.error", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
