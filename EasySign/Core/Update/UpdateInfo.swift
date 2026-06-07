import Foundation

/// 一个可用更新的展示信息。
struct UpdateInfo: Equatable, Identifiable {
    var id: String { version }
    let version: String        // 规范化版本,如 "1.0.3"
    let releaseNotes: String
    let dmgURL: URL
    let publishedAt: Date?
}

/// 纯逻辑:把 GitHub `/releases/latest` 的 JSON 解析成可用字段。
enum GitHubReleaseParser {
    struct Parsed: Equatable {
        let tagName: String
        let body: String
        let dmgURL: URL?
        let publishedAt: Date?
    }

    private struct Release: Decodable {
        let tag_name: String
        let body: String?
        let published_at: String?
        let assets: [Asset]?
        struct Asset: Decodable { let name: String; let browser_download_url: String }
    }

    static func parse(_ data: Data) throws -> Parsed {
        let r = try JSONDecoder().decode(Release.self, from: data)
        let dmgAsset = (r.assets ?? []).first { $0.name.lowercased().hasSuffix(".dmg") }
        let dmgURL = dmgAsset.flatMap { URL(string: $0.browser_download_url) }
        let date = r.published_at.flatMap { ISO8601DateFormatter().date(from: $0) }
        return Parsed(tagName: r.tag_name, body: r.body ?? "", dmgURL: dmgURL, publishedAt: date)
    }
}
