import Foundation
import SwiftUI

@main
struct GlassSidebarRecipeTests {
    static func main() {
        expect(
            GlassSidebarRecipe.railWhiteOverlayOpacity(for: .light) >= 0.3,
            "the light sidebar remains distinctly white"
        )
        expect(
            GlassSidebarRecipe.selectedFillOpacity(for: .light)
                > GlassSidebarRecipe.railWhiteOverlayOpacity(for: .light),
            "the selected navigation item is brighter than the rail"
        )
        expect(
            GlassSidebarRecipe.selectedBorderOpacity(for: .light) >= 0.75,
            "the selected navigation item has a crisp white edge"
        )
        expect(
            GlassSidebarRecipe.selectedFillOpacity(for: .dark)
                > GlassSidebarRecipe.railWhiteOverlayOpacity(for: .dark),
            "the dark selected navigation item remains distinct from its rail"
        )
        expect(
            GlassSidebarRecipe.dividerOpacity(for: .dark) > 0,
            "the dark navigation rail retains a visible divider"
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
