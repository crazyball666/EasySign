import Foundation
import SwiftUI

@main
struct GlassThemePreferenceTests {
    static func main() {
        expect(GlassThemePreference(rawValue: "system") == .system, "system raw value decodes")
        expect(GlassThemePreference(rawValue: "light") == .light, "light raw value decodes")
        expect(GlassThemePreference(rawValue: "dark") == .dark, "dark raw value decodes")
        expect(GlassThemePreference(rawValue: "solarized") == nil, "unknown raw value is rejected")

        expect(GlassThemePreference.system.resolvedColorScheme == nil, "system follows macOS")
        expect(GlassThemePreference.light.resolvedColorScheme == .light, "light forces light scheme")
        expect(GlassThemePreference.dark.resolvedColorScheme == .dark, "dark forces dark scheme")
        expect(SettingsKey.interfaceTheme.rawValue == "interfaceTheme", "theme preference has stable settings key")

        print("ALL PASS")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }
}
