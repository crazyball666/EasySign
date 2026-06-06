import Foundation

public enum ToolCategory: String, CaseIterable, Identifiable {
    case active    = "今日活跃"
    case frequent  = "常用"
    case advanced  = "高级"

    public var id: String { rawValue }
}
