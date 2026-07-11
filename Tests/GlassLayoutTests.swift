import Foundation

@main
struct GlassLayoutTests {
    static func main() {
        expect(
            GlassLayout.contextPresentation(for: 1180) == .rail,
            "1180pt keeps the context rail"
        )
        expect(
            GlassLayout.contextPresentation(for: 1179) == .inspector,
            "below 1180pt moves context into an inspector"
        )

        expect(
            GlassLayout.deviceSelectorPresentation(forDetailWidth: 980) == .rail,
            "980pt keeps the device rail"
        )
        expect(
            GlassLayout.deviceSelectorPresentation(forDetailWidth: 979) == .topPicker,
            "below 980pt uses the top device picker"
        )

        expect(
            GlassLayout.sidebarMode(for: 820) == .labelledRail,
            "820pt keeps sidebar labels"
        )
        expect(
            GlassLayout.sidebarMode(for: 819) == .iconRail,
            "below 820pt uses the icon rail"
        )
        expect(
            GlassLayout.sidebarMode(for: 700) == .iconRail,
            "700pt keeps the icon rail"
        )
        expect(
            GlassLayout.sidebarMode(for: 699) == .systemCollapsed,
            "below 700pt lets NavigationSplitView collapse"
        )

        expect(
            GlassSidebarMode.iconRail.accessibilityLabel == "仅图标导航",
            "icon rail has a readable accessibility label"
        )
        expect(
            GlassContextPresentation.inspector.accessibilityLabel == "检查器",
            "inspector has a readable accessibility label"
        )

        print("ALL PASS")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }
}
