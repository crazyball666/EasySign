//
//  Date.swift
//  EasySign
//
//  Created by crazyball on 2024/11/2.
//

import Foundation

extension Date {
    /// 时间格式化
    /// - Parameter format: 格式
    /// - Returns: 时间字符串
    func formatString(format: String = "yyyy/MM/dd HH:mm:ss") -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter.string(from: self)
    }
}
