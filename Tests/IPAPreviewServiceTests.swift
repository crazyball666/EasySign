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
        try sampleProvisioningProfile.write(to: app.appendingPathComponent("embedded.mobileprovision"))
        try Data().write(to: app.appendingPathComponent("libInjected.dylib"))
        try Data().write(to: kitFramework.appendingPathComponent("Kit"))
        try Data().write(to: app.appendingPathComponent("DemoExec"))
        let codeSignature = app.appendingPathComponent("_CodeSignature", isDirectory: true)
        try FileManager.default.createDirectory(at: codeSignature, withIntermediateDirectories: true)
        try Data("codesign resources".utf8).write(to: codeSignature.appendingPathComponent("CodeResources"))

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
        assert(preview.codeSignature.hasCodeResources, "code resources")
        assert(preview.signingDescription.contains("已包含 CodeResources"), "signing description")
        assert(preview.provisioningProfile?.name == "Preview Development", "profile name")
        assert(preview.provisioningProfile?.teamName == "Preview Team", "team name")
        assert(preview.provisioningProfile?.profileType == "Development", "profile type")
        assert(preview.provisioningProfile?.provisionedDeviceCount == 2, "device count")
        assert(preview.provisioningProfile?.apsEnvironment == "development", "aps environment")
        assert(preview.provisioningProfile?.getTaskAllow == true, "get-task-allow")
        assert(preview.provisioningProfile?.certificates.first?.commonName.contains("Preview Tester") == true, "certificate common name")
        assert(preview.provisioningProfile?.certificates.first?.teamIdentifier == "ABCDE12345", "certificate team id")
        assert(preview.fileSize > 0, "file size")

        try? FileManager.default.removeItem(at: tempRoot)
    }

    static var sampleProvisioningProfile: Data {
        let certData = Data(base64Encoded: """
        MIIDYDCCAkgCCQDE2Trw/tTnOjANBgkqhkiG9w0BAQsFADByMTcwNQYDVQQDDC5BcHBsZSBEZXZlbG9wbWVudDogUHJldmlldyBUZXN0ZXIgKEFCQ0RFMTIzNDUpMRMwEQYDVQQLDApBQkNERTEyMzQ1MRUwEwYDVQQKDAxQcmV2aWV3IFRlYW0xCzAJBgNVBAYTAlVTMB4XDTI2MDUzMDE4NTAzMloXDTI3MDUzMDE4NTAzMlowcjE3MDUGA1UEAwwuQXBwbGUgRGV2ZWxvcG1lbnQ6IFByZXZpZXcgVGVzdGVyIChBQkNERTEyMzQ1KTETMBEGA1UECwwKQUJDREUxMjM0NTEVMBMGA1UECgwMUHJldmlldyBUZWFtMQswCQYDVQQGEwJVUzCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAMQNqqOEbZg4rJkZXwNaxEabw5Jt4b2CvD52T2RUsfuPCd4rc4OoeOGUSlRfKEt+nsfqbEifNm0EN7TWjQ1THf+pAKHG2rfQGb+CXQQmpx1daYNVjsiXQ7fAZk1M57gP9FTklO79GUzIhifx1WkWsSY8ZgwWznVYJhrnQZeZDXHC6PVdA6QNKznFH1sHcmYd5LgMMykXn55nY2wlDx6HQy0hsIirM6LEeJr/I2tR6vFq3fmFnNYbeNRYXYoSlUwbBdM91UfhxBOu7UHSxmLq5JcwhAa6qLLDzdJt7bnYtMTrtmAJt74Tku38RRbo90smlNd22EFs7vMcYqr2ds4EXO0CAwEAATANBgkqhkiG9w0BAQsFAAOCAQEAOFyHYcWgGedIETnS2LPtvNw2STMFe6gaCbj8WCGTFtHmlbTKS5vSi6BjRpGMeHI8JG0GyHPz2IpRo4ZIcjlNzipYt2bIN288PSuackph6EAxL28fBq7xt139bvTPSPVtjvAP5Lu0pkd3jl5PMOhoPH6jZrF62+hqBDJFrGMY4BxCl7CkTQNekCZE0PKoHwE1lFGKXamr2fIiPJElNRiogWttORuofaVrAQ95lkVodJTMm1+QGCGtEmX5G4fwNEUCCar+jkB32LDmtLj4u6WUWTm7aI6Ger6fx/jFZcaCV26SB1XAylhxo0eAkrT1/N837LduC0BOkQTM2Rfx9gdD/A==
        """.filter { !$0.isWhitespace })!

        let profile: [String: Any] = [
            "Name": "Preview Development",
            "UUID": "00000000-0000-0000-0000-000000000001",
            "TeamName": "Preview Team",
            "TeamIdentifier": ["ABCDE12345"],
            "CreationDate": Date(timeIntervalSince1970: 1_700_000_000),
            "ExpirationDate": Date(timeIntervalSince1970: 1_900_000_000),
            "ProvisionedDevices": ["DEVICE-2", "DEVICE-1"],
            "DeveloperCertificates": [certData],
            "Entitlements": [
                "application-identifier": "ABCDE12345.com.example.demo",
                "aps-environment": "development",
                "com.apple.developer.team-identifier": "ABCDE12345",
                "get-task-allow": true
            ]
        ]

        return try! PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
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
