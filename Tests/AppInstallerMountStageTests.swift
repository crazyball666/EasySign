import Foundation

/// 集成测试:真的造一个 DMG → AppInstaller.mountAndStage 挂载/找 .app/ditto/卸载 → 断言产物。
/// 这段不像替换+重启那样有副作用(无 NSApp.terminate、无替换 /Applications),可在本地真跑。
/// 注:独立测试可执行文件里 Bundle.main.bundleIdentifier 为 nil,故 bundle-id 防呆不触发(只在 App 内生效)。
///
/// 期望输出:`ALL PASS`,否则 `FAIL: ...` 到 stderr + exit(1)。

@main
struct AppInstallerMountStageTests {
    static func main() {
        do { try run() } catch { fail("threw: \(error)") }
    }

    static func run() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("eztx-ms-\(getpid())", isDirectory: true)
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 1. 造假 .app(含 Info.plist + 一个标记文件,用于验证 ditto 完整复制)
        let src = work.appendingPathComponent("src", isDirectory: true)
        let appContents = src.appendingPathComponent("Dummy.app/Contents", isDirectory: true)
        try fm.createDirectory(at: appContents, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.example.dummy</string>
        </dict></plist>
        """
        try plist.write(to: appContents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try Data([7, 7, 7]).write(to: appContents.appendingPathComponent("marker.bin"))

        // 2. hdiutil 打成 DMG
        let dmg = work.appendingPathComponent("test.dmg")
        let mk = Process()
        mk.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        mk.arguments = ["create", "-volname", "DummyVol", "-srcfolder", src.path, "-ov", "-format", "UDZO", dmg.path]
        let mkErr = Pipe(); mk.standardError = mkErr; mk.standardOutput = Pipe()
        try mk.run()
        let mkE = mkErr.fileHandleForReading.readDataToEndOfFile(); mk.waitUntilExit()
        expect(mk.terminationStatus == 0, "hdiutil create 应成功: \(String(data: mkE, encoding: .utf8) ?? "")")

        // 3. mountAndStage(真实挂载 → ditto → 卸载)
        let staged = try AppInstaller.mountAndStage(dmg: dmg)
        defer { try? fm.removeItem(at: staged.deletingLastPathComponent()) }

        // 4. 断言:卸载后 staged 仍在(说明已复制成独立副本,而非指向已卸载的挂载点),且内容完整
        expect(staged.pathExtension == "app", "staged 应是 .app,实际 \(staged.lastPathComponent)")
        expect(fm.fileExists(atPath: staged.appendingPathComponent("Contents/Info.plist").path),
               "staged 应含 Info.plist")
        let marker = staged.appendingPathComponent("Contents/marker.bin")
        expect(fm.fileExists(atPath: marker.path), "staged 应含原标记文件(ditto 完整复制)")
        expect((try? Data(contentsOf: marker)) == Data([7, 7, 7]), "标记文件内容应一致")

        print("ALL PASS")
    }

    static func expect(_ c: Bool, _ m: String) { if !c { fail(m) } }
    static func fail(_ m: String) {
        FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8))
        exit(1)
    }
}
