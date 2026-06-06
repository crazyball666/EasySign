import Foundation
import AppKit

public final class ArtifactStore: ObservableObject {
    private let logger: LoggerService
    private let storeURL: URL
    private var artifacts: [UUID: ResignArtifact] = [:]
    private let queue = DispatchQueue(label: "ArtifactStore")

    /// @Published 触发 SwiftUI 重新渲染。StatusBar 等观察者依赖此。
    @Published private(set) var sortedArtifacts: [ResignArtifact] = []

    public init(logger: LoggerService) {
        self.logger = logger
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("EasySign", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("artifacts.json")
        load()
        recomputeSorted()
    }

    @discardableResult
    public func startRun(tool: String, inputIPA: URL?) -> UUID {
        let runId = UUID()
        let logs = makeLogsDir().appendingPathComponent("\(runId.uuidString).log")
        let workspace = makeWorkspace().appendingPathComponent(runId.uuidString)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let artifact = ResignArtifact(id: runId, runId: runId, startedAt: Date(),
                                       finishedAt: nil, inputIPA: inputIPA, outputIPA: nil,
                                       logPath: logs, workspacePath: workspace,
                                       status: .running, tool: tool, summary: "")
        queue.sync {
            artifacts[runId] = artifact
            save()
            recomputeSortedLocked()
        }
        logger.setCurrentRun(runId)
        return runId
    }

    public func finishRun(_ runId: UUID, status: ResignArtifact.Status,
                          outputIPA: URL?, summary: String) {
        queue.sync {
            guard let prev = artifacts[runId] else { return }
            let updated = ResignArtifact(id: prev.id, runId: prev.runId, startedAt: prev.startedAt,
                                          finishedAt: Date(), inputIPA: prev.inputIPA,
                                          outputIPA: outputIPA, logPath: prev.logPath,
                                          workspacePath: prev.workspacePath, status: status,
                                          tool: prev.tool, summary: summary)
            artifacts[runId] = updated
            save()
            recomputeSortedLocked()
        }
        logger.setCurrentRun(nil)
    }

    public func artifact(forRun runId: UUID) -> ResignArtifact? {
        queue.sync { artifacts[runId] }
    }

    public func allArtifacts(tool: String? = nil, limit: Int = 50) -> [ResignArtifact] {
        queue.sync {
            let filtered: [ResignArtifact]
            if let t = tool {
                filtered = artifacts.values.filter { $0.tool == t }
            } else {
                filtered = Array(artifacts.values)
            }
            return Array(filtered.sorted { $0.startedAt > $1.startedAt }.prefix(limit))
        }
    }

    public var latest: ResignArtifact? {
        queue.sync { sortedArtifacts.first }
    }

    public func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func cleanupExpired(retentionDays: Int = 7) {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        queue.sync {
            for (id, a) in artifacts where a.startedAt < cutoff {
                try? FileManager.default.removeItem(at: a.workspacePath)
                artifacts.removeValue(forKey: id)
            }
            save()
            recomputeSortedLocked()
        }
    }

    /// 在 queue 内调用：刷新 published 数组。
    private func recomputeSortedLocked() {
        let sorted = artifacts.values.sorted { $0.startedAt > $1.startedAt }
        // 在主线程发布，避免 ObservableObject 跨线程警告
        DispatchQueue.main.async { [weak self] in
            self?.sortedArtifacts = sorted
        }
    }

    /// 在 queue 外调用：便利方法。
    private func recomputeSorted() {
        queue.sync { recomputeSortedLocked() }
    }

    private func makeLogsDir() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("EasySign/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeWorkspace() -> URL {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = cache.appendingPathComponent("EasySign/ResignTask", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([ResignArtifact].self, from: data) else { return }
        for a in decoded { artifacts[a.runId] = a }
    }

    private func save() {
        let values = Array(artifacts.values)
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
