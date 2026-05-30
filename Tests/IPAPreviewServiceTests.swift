import Foundation

@main
struct IPAPreviewServiceTests {
    static func main() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("easysign-ipa-preview-\(UUID().uuidString)", isDirectory: true)
        let payload = tempRoot.appendingPathComponent("Payload", isDirectory: true)
        let app = payload.appendingPathComponent("Demo.app", isDirectory: true)
        let plugIns = app.appendingPathComponent("PlugIns", isDirectory: true)
        let shareExtension = plugIns.appendingPathComponent("Share.appex", isDirectory: true)
        let frameworks = app.appendingPathComponent("Frameworks", isDirectory: true)
        let kitFramework = frameworks.appendingPathComponent("Kit.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: shareExtension, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: kitFramework, withIntermediateDirectories: true)

        let appInfo: [String: Any] = [
            "CFBundleDisplayName": "Demo App",
            "CFBundleIdentifier": "com.example.demo",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45",
            "CFBundleExecutable": "DemoExec",
            "MinimumOSVersion": "15.0"
        ]
        let appexInfo: [String: Any] = [
            "CFBundleDisplayName": "Share Extension",
            "CFBundleIdentifier": "com.example.demo.share",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1"
        ]
        try (appInfo as NSDictionary).write(to: app.appendingPathComponent("Info.plist"))
        try (appexInfo as NSDictionary).write(to: shareExtension.appendingPathComponent("Info.plist"))
        try Data().write(to: app.appendingPathComponent("libInjected.dylib"))
        try Data().write(to: kitFramework.appendingPathComponent("Kit"))
        try Data().write(to: app.appendingPathComponent("DemoExec"))

        let ipaPath = tempRoot.appendingPathComponent("Demo.ipa")
        try run("/usr/bin/zip", ["-qry", ipaPath.path, "Payload"], currentDirectory: tempRoot)

        let preview = try IPAPreviewService().preview(url: ipaPath)

        assert(preview.fileName == "Demo.ipa", "file name")
        assert(preview.appName == "Demo App", "app name")
        assert(preview.bundleIdentifier == "com.example.demo", "bundle id")
        assert(preview.version == "1.2.3", "version")
        assert(preview.buildVersion == "45", "build version")
        assert(preview.minimumOSVersion == "15.0", "minimum os")
        assert(preview.executableName == "DemoExec", "executable")
        assert(preview.appDirectoryName == "Demo.app", "app directory")
        assert(preview.appexes.map(\.bundleIdentifier) == ["com.example.demo.share"], "appex bundle id")
        assert(preview.frameworks == ["Kit.framework"], "frameworks")
        assert(preview.dynamicLibraries == ["libInjected.dylib"], "dynamic libraries")
        assert(preview.fileSize > 0, "file size")

        try? FileManager.default.removeItem(at: tempRoot)
    }

    static func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("Assertion failed: \(message)\n".utf8))
            exit(1)
        }
    }

    static func run(_ executable: String, _ arguments: [String], currentDirectory: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "IPAPreviewServiceTests", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "\(executable) failed with status \(process.terminationStatus)"
            ])
        }
    }
}
