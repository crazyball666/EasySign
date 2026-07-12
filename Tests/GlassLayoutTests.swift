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

        let navigationIDs = ["resign", "qr", "devices", "transfer"]
        expect(
            GlassSidebarNavigation.selection(afterMovingFrom: "qr", in: navigationIDs, direction: .down) == "devices",
            "down arrow moves to the following navigation item"
        )
        expect(
            GlassSidebarNavigation.selection(afterMovingFrom: "qr", in: navigationIDs, direction: .up) == "resign",
            "up arrow moves to the previous navigation item"
        )
        expect(
            GlassSidebarNavigation.selection(afterMovingFrom: "resign", in: navigationIDs, direction: .up) == "resign",
            "up arrow stops at the first navigation item"
        )
        expect(
            GlassSidebarNavigation.selection(afterMovingFrom: nil, in: navigationIDs, direction: .down) == "resign",
            "an unfocused sidebar starts at its first navigation item"
        )
        expect(
            GlassSidebarNavigation.selection(afterMovingFrom: "transfer", in: navigationIDs, direction: .down) == "transfer",
            "down arrow stops at the final navigation item"
        )
        expect(
            GlassSidebarNavigation.selection(afterMovingFrom: "missing", in: navigationIDs, direction: .down) == "resign",
            "an unknown selected item falls back to the first navigation item"
        )
        expect(
            GlassSidebarNavigation.selection(afterMovingFrom: nil, in: [], direction: .down) == nil,
            "an empty sidebar has no selection target"
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
