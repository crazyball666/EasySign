//
//  Logger.swift
//  EasySign
//
//  Created by crazyball on 2025/6/2.
//

import Foundation

enum LogLevel: String {
    case INFO
    case ERROR
}

protocol LoggerProtocol {
    func log(_ level: LogLevel, _ text: String)
}

struct ConsoleLogger: LoggerProtocol {
    static let shared = ConsoleLogger()
    
    func log(_ level: LogLevel, _ text: String) {
        print("[\(level.rawValue)] \(text)")
    }
}
