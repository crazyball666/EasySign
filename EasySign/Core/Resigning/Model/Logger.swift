//
//  Logger.swift
//  EasySign
//
//  Created by crazyball on 2025/6/2.
//

import Foundation

// 注意：旧的 LogLevel 已重命名为 LegacyLogLevel 以避免和 Core/Logging/LogLevel.swift 冲突
enum LegacyLogLevel: String {
    case INFO
    case ERROR
}

protocol LoggerProtocol {
    func log(_ level: LegacyLogLevel, _ text: String)
}

struct ConsoleLogger: LoggerProtocol {
    static let shared = ConsoleLogger()

    func log(_ level: LegacyLogLevel, _ text: String) {
        print("[\(level.rawValue)] \(text)")
    }
}
