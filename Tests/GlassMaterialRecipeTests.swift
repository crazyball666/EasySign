import Foundation
import SwiftUI

@main
struct GlassMaterialRecipeTests {
    static func main() {
        expect(
            GlassMaterialRecipe.overlayOpacity(for: .standard, colorScheme: .light) < 0.5,
            "standard light surfaces leave the canvas visible"
        )
        expect(
            GlassMaterialRecipe.overlayOpacity(for: .emphasized, colorScheme: .light)
                < GlassMaterialRecipe.overlayOpacity(for: .standard, colorScheme: .light),
            "the navigation rail is lighter than content cards"
        )
        expect(
            GlassMaterialRecipe.borderOpacity(for: .emphasized, colorScheme: .light) < 0.5,
            "the navigation rail avoids a hard white outline"
        )
        expect(
            GlassMaterialRecipe.highlightOpacity(for: .standard, colorScheme: .light) > 0,
            "glass surfaces retain a subtle highlight"
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
