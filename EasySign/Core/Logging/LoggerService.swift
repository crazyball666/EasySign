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
    private var _bumpScheduled = false

    /// 递增计数,仅用于驱动 SwiftUI 刷新(_buffer 在后台队列变更,不能直接 @Published)。
    @Published public private(set) var revision: Int = 0

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
        scheduleRefresh()
    }

    // 合并高频日志的刷新:一个 runloop tick 内只发一次 @Published 变更,
    // 取代 LogPanelView 之前的 0.5s 轮询定时器。
    private func scheduleRefresh() {
        let alreadyScheduled: Bool = queue.sync {
            if _bumpScheduled { return true }
            _bumpScheduled = true
            return false
        }
        if alreadyScheduled { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queue.sync { self._bumpScheduled = false }
            self.revision &+= 1
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
