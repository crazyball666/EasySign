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

public final class LoggerService: ObservableObject {
    private let queue = DispatchQueue(label: "LoggerService")
    private var _buffer: [LogEntry] = []
    private var _currentRunId: UUID?

    public init() {}

    public static func live() -> LoggerService { LoggerService() }

    public func log(_ level: LogLevel, tool: String, _ message: String) {
        log(level, tool: tool, category: "", message)
    }

    public func log(_ level: LogLevel, tool: String, category: String, _ message: String) {
        queue.sync {
            let entry = LogEntry(runId: _currentRunId, level: level,
                                  category: category, tool: tool, message: message)
            _buffer.append(entry)
            if _buffer.count > 1000 { _buffer.removeFirst() }
        }
    }

    public var recentEntries: [LogEntry] {
        queue.sync { _buffer }
    }

    public func entries(forRun runId: UUID) -> [LogEntry] {
        queue.sync { _buffer.filter { $0.runId == runId } }
    }

    public func setCurrentRun(_ runId: UUID?) {
        queue.sync { _currentRunId = runId }
    }
}
