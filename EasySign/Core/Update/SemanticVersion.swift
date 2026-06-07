import Foundation

/// 语义版本号 X.Y.Z(容忍前缀 v、缺位补 0;非法返回 nil)。
struct SemanticVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 1, parts.count <= 3 else { return nil }
        var nums = [0, 0, 0]
        for (i, p) in parts.enumerated() {
            guard let n = Int(p), n >= 0 else { return nil }
            nums[i] = n
        }
        major = nums[0]; minor = nums[1]; patch = nums[2]
    }

    var displayString: String { "\(major).\(minor).\(patch)" }
    func isNewer(than other: SemanticVersion) -> Bool { self > other }
    static func < (l: SemanticVersion, r: SemanticVersion) -> Bool {
        (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
    }
}
