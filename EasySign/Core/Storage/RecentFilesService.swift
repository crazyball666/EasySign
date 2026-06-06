import Foundation

public struct RecentFile: Identifiable, Codable {
    public let url: URL
    public let kind: RecentFileKind
    public var lastUsed: Date
    public var useCount: Int
    public var id: URL { url }
}

public final class RecentFilesService {
    private let storeURL: URL
    private let cap: Int
    private var files: [RecentFile] = []
    private let queue = DispatchQueue(label: "RecentFilesService")

    public init(cap: Int = 20) {
        self.cap = cap
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("EasySign", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("recent.json")
        load()
    }

    public func record(_ url: URL, kind: RecentFileKind) {
        queue.sync {
            if let i = files.firstIndex(where: { $0.url == url && $0.kind == kind }) {
                files[i].lastUsed = Date()
                files[i].useCount += 1
            } else {
                files.append(RecentFile(url: url, kind: kind, lastUsed: Date(), useCount: 1))
            }
            files.sort { $0.lastUsed > $1.lastUsed }
            if files.count > cap { files = Array(files.prefix(cap)) }
            save()
        }
    }

    public func all(kind: RecentFileKind? = nil) -> [RecentFile] {
        queue.sync {
            if let k = kind {
                return files.filter { $0.kind == k }
            }
            return files
        }
    }

    public func remove(_ url: URL, kind: RecentFileKind) {
        queue.sync {
            files.removeAll { $0.url == url && $0.kind == kind }
            save()
        }
    }

    public func clear(kind: RecentFileKind? = nil) {
        queue.sync {
            if let k = kind {
                files.removeAll { $0.kind == k }
            } else {
                files.removeAll()
            }
            save()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([RecentFile].self, from: data) else { return }
        self.files = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(files) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
