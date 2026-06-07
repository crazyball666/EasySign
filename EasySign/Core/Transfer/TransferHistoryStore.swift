import Foundation

/// 历史索引持久化到 Application Support/EasySign/Transfer/history.json,容量上限 + 按天清理。
final class TransferHistoryStore {
    private let cap: Int
    private let fileURL: URL
    init(cap: Int = 200) {
        self.cap = cap
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EasySign/Transfer", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("history.json")
    }
    func load() -> [TransferItem] {
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([TransferItem].self, from: data) else { return [] }
        return items
    }
    func save(_ items: [TransferItem]) {
        let capped = Array(items.prefix(cap))
        if let data = try? JSONEncoder().encode(capped) { try? data.write(to: fileURL) }
    }
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
    /// 删除早于 cutoff 的项,返回保留项。
    func pruning(_ items: [TransferItem], olderThan cutoff: Date) -> [TransferItem] {
        items.filter { $0.timestamp >= cutoff }
    }
}
