import Foundation

@main
struct SemanticVersionTests {
    static func main() {
        expect(SemanticVersion("v1.2.3") == SemanticVersion("1.2.3"), "v-prefix")
        expect(SemanticVersion("1.2")?.patch == 0, "missing patch → 0")
        expect(SemanticVersion("1")?.minor == 0, "missing minor → 0")
        expect(SemanticVersion("abc") == nil, "invalid nil")
        expect(SemanticVersion("") == nil, "empty nil")
        expect(SemanticVersion("1.0.10")! > SemanticVersion("1.0.9")!, "10 > 9 numeric")
        expect(SemanticVersion("1.2.0")! > SemanticVersion("1.1.9")!, "minor wins")
        expect(SemanticVersion("2.0.0")! > SemanticVersion("1.9.9")!, "major wins")
        expect(SemanticVersion("1.2.3")! == SemanticVersion("1.2.3")!, "equal")
        expect(SemanticVersion("1.0.3")!.isNewer(than: SemanticVersion("1.0.2")!), "isNewer")
        expect(!SemanticVersion("1.0.2")!.isNewer(than: SemanticVersion("1.0.2")!), "same not newer")
        expect(SemanticVersion("v1.0.3")!.displayString == "1.0.3", "displayString")
        print("ALL PASS")
    }
    static func expect(_ c: Bool, _ m: String) {
        if !c { FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); exit(1) }
    }
}
