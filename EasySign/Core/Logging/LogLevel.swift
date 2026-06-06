import Foundation

public enum LogLevel: String, Codable, Comparable {
    case debug, info, warn, error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        order(lhs) < order(rhs)
    }

    private static func order(_ l: LogLevel) -> Int {
        switch l {
        case .debug: return 0
        case .info:  return 1
        case .warn:  return 2
        case .error: return 3
        }
    }
}
