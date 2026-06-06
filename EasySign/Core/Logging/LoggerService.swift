import Foundation

public struct LogEntry: Identifiable, Codable {
    public let id: UUID
    public let runId: UUID?
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let tool: String
    public let message: String

    public init(id: UUID = UUID(), runId: UUID? = nil, timestamp: Date = Date(),
                level: LogLevel, category: String = "", tool: String, message: String) {
        self.id = id
        self.runId = runId
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.tool = tool
        self.message = message
    }
}

public final class LoggerService {
    private var buffer: [LogEntry] = []
    public private(set) var currentRunId: UUID?

    public init() {}

    public static func live() -> LoggerService { LoggerService() }

    public func log(_ level: LogLevel, tool: String, _ message: String) {
        log(level, tool: tool, category: "", message)
    }

    public func log(_ level: LogLevel, tool: String, category: String, _ message: String) {
        let entry = LogEntry(runId: currentRunId, level: level,
                              category: category, tool: tool, message: message)
        buffer.append(entry)
        if buffer.count > 1000 { buffer.removeFirst() }
    }

    public var recentEntries: [LogEntry] { buffer }

    public func entries(forRun runId: UUID) -> [LogEntry] {
        buffer.filter { $0.runId == runId }
    }

    public func setCurrentRun(_ runId: UUID?) { currentRunId = runId }
}
