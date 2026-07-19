import Foundation

/// GitHub release 正文解析后的结构。
///
/// 为什么不直接把正文丢给 Text:GitHub 的 release body 是 Markdown,`Text` 原样渲染
/// 会把 `**Full Changelog**:` 这种标记当字面量显示,链接也点不了。而自动生成的
/// release 里往往**只有**那一行 Full Changelog —— 在 460pt 宽的弹窗里换行成两行
/// 裸 URL,占满视野却一个字的信息量都没有。这里把它单独摘出来交给按钮,正文
/// 只留真正的说明。
struct ReleaseNotes: Equatable {
    enum Block: Equatable {
        case heading(String)
        case bullet(String)
        case paragraph(String)
    }

    let blocks: [Block]
    /// GitHub 自动附加的 "Full Changelog" 对比链接,没有则为 nil。
    let fullChangelogURL: URL?

    /// 没有任何实质说明(只有自动生成的链接,或正文本来就是空的)。
    var hasNoDescription: Bool { blocks.isEmpty }
}

enum ReleaseNotesParser {
    /// 只做行级结构切分;粗体/链接等行内标记留给渲染层用 AttributedString 处理。
    static func parse(_ markdown: String) -> ReleaseNotes {
        var blocks: [ReleaseNotes.Block] = []
        var changelogURL: URL?

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if let url = fullChangelogURL(in: line) {
                changelogURL = url
                continue    // 不进正文,改由按钮承载
            }

            if line.hasPrefix("#") {
                let text = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { blocks.append(.heading(text)) }
                continue
            }

            if let marker = ["- ", "* ", "+ "].first(where: { line.hasPrefix($0) }) {
                let text = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { blocks.append(.bullet(text)) }
                continue
            }

            // 分隔线不承载信息
            if line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }), line.count >= 3 { continue }

            blocks.append(.paragraph(line))
        }

        return ReleaseNotes(blocks: blocks, fullChangelogURL: changelogURL)
    }

    /// 匹配 "**Full Changelog**: <url>" / "Full Changelog: <url>" 等变体(大小写不敏感)。
    private static func fullChangelogURL(in line: String) -> URL? {
        let stripped = line.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        guard stripped.lowercased().hasPrefix("full changelog") else { return nil }
        guard let colon = stripped.firstIndex(of: ":") else { return nil }
        let tail = stripped[stripped.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        // 冒号后可能是裸 URL,也可能是 [text](url) 形式
        if let open = tail.firstIndex(of: "("), let close = tail.lastIndex(of: ")"), open < close {
            return URL(string: String(tail[tail.index(after: open)..<close]))
        }
        return URL(string: tail)
    }
}
