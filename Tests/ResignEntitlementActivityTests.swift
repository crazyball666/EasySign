import Foundation

@main
struct ResignEntitlementActivityTests {
    static func main() {
        let messages = [
            "开始 zsign 重签名...",
            "zsign entitlement 保留：aps-environment（profile-authoritative）",
            "zsign entitlement 移除：get-task-allow（profile false）",
            "zsign entitlement 改写：application-identifier（derived from profile）",
            "重签名完成🎉🎉🎉"
        ]

        expect(ResignActivitySummary.rewriteCount(in: messages) == 2, "counts only removed and rewritten entitlement events")
        expect(ResignActivitySummary.rewriteCount(in: []) == 0, "empty activity has no rewrites")
        print("ALL PASS")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }
}
