import Foundation

@main
struct GlassStatusTests {
    static func main() {
        expect(GlassStatus.active.isAnimated, "active status animates")
        expect(!GlassStatus.success.isAnimated, "success status is static")
        expect(GlassStatus.warning.symbol == "exclamationmark.triangle.fill", "warning has a semantic symbol")
        expect(GlassStatus.danger.accessibilityLabel == "失败", "danger has a readable label")
        expect(GlassStatus.idle.title == "待命", "idle has a stable title")
        print("ALL PASS")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }
}
