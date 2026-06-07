import Foundation

@main
struct GitHubReleaseParserTests {
    static func main() throws {
        let json = """
        {
          "tag_name": "v1.0.3",
          "body": "修复若干问题\\n- a\\n- b",
          "published_at": "2026-06-07T10:00:00Z",
          "assets": [
            { "name": "EasySign-1.0.3.dmg", "browser_download_url": "https://github.com/crazyball666/EasySign/releases/download/v1.0.3/EasySign-1.0.3.dmg" },
            { "name": "source.zip", "browser_download_url": "https://example.com/x.zip" }
          ]
        }
        """
        let p = try GitHubReleaseParser.parse(Data(json.utf8))
        expect(p.tagName == "v1.0.3", "tagName")
        expect(p.body.contains("修复若干问题"), "body")
        expect(p.dmgURL?.absoluteString.hasSuffix("EasySign-1.0.3.dmg") == true, "dmg url picked")
        expect(p.publishedAt != nil, "date parsed")

        let noDmg = """
        { "tag_name": "v1.0.4", "assets": [ { "name": "x.zip", "browser_download_url": "https://e/x.zip" } ] }
        """
        let p2 = try GitHubReleaseParser.parse(Data(noDmg.utf8))
        expect(p2.dmgURL == nil, "no dmg → nil")
        expect(p2.body == "", "missing body → empty")

        do { _ = try GitHubReleaseParser.parse(Data("not json".utf8)); fail("should throw") } catch {}
        print("ALL PASS")
    }
    static func expect(_ c: Bool, _ m: String) { if !c { fail(m) } }
    static func fail(_ m: String) -> Never { FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); exit(1) }
}
