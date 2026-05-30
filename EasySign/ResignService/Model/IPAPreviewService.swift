//
//  IPAPreviewService.swift
//  EasySign
//

import CryptoKit
import Foundation
import Security

struct IPAPreviewEmbeddedBundle: Identifiable, Equatable {
    var id: String { bundleIdentifier }
    let name: String
    let bundleIdentifier: String
    let version: String
    let buildVersion: String
}

struct IPAPreviewProvisioningProfile: Equatable {
    let name: String
    let uuid: String
    let teamName: String
    let teamIdentifier: String
    let applicationIdentifier: String
    let profileType: String
    let creationDate: Date?
    let expirationDate: Date?
    let provisionedDeviceCount: Int
    let provisionsAllDevices: Bool
    let apsEnvironment: String?
    let getTaskAllow: Bool?
    let entitlementKeys: [String]
    let certificates: [IPAPreviewCertificate]
}

struct IPAPreviewCertificate: Identifiable, Equatable {
    var id: String { sha1Fingerprint.isEmpty ? commonName : sha1Fingerprint }
    let commonName: String
    let organization: String
    let teamIdentifier: String
    let countryName: String
    let notBefore: Date?
    let notAfter: Date?
    let sha1Fingerprint: String
}

struct IPAPreviewCodeSignature: Equatable {
    let hasCodeResources: Bool
    let codeResourcesPath: String?
}

struct IPAPreviewInfo: Identifiable {
    var id: String { fileURL.path }
    let fileURL: URL
    let fileName: String
    let fileSize: Int64
    let appDirectoryName: String
    let appName: String
    let bundleIdentifier: String
    let version: String
    let buildVersion: String
    let minimumOSVersion: String?
    let executableName: String?
    let iconData: Data?
    let codeSignature: IPAPreviewCodeSignature
    let provisioningProfile: IPAPreviewProvisioningProfile?
    let appexes: [IPAPreviewEmbeddedBundle]
    let frameworks: [String]
    let dynamicLibraries: [String]

    var versionDescription: String {
        if version.isEmpty && buildVersion.isEmpty {
            return "-"
        }
        if buildVersion.isEmpty {
            return version
        }
        if version.isEmpty {
            return "Build \(buildVersion)"
        }
        return "\(version) (\(buildVersion))"
    }

    var signingDescription: String {
        var parts: [String] = []
        if codeSignature.hasCodeResources {
            parts.append("已包含 CodeResources")
        } else {
            parts.append("未发现 CodeResources")
        }
        if let provisioningProfile {
            parts.append(provisioningProfile.profileType)
            if !provisioningProfile.teamIdentifier.isEmpty {
                parts.append("Team ID: \(provisioningProfile.teamIdentifier)")
            }
        } else {
            parts.append("未内嵌描述文件")
        }
        return parts.joined(separator: " · ")
    }
}

enum IPAPreviewError: LocalizedError {
    case unsupportedInput
    case missingAppBundle
    case missingInfoPlist
    case invalidInfoPlist
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedInput:
            return "仅支持预览 .ipa、.zip 或 .app"
        case .missingAppBundle:
            return "找不到 Payload 里的 .app"
        case .missingInfoPlist:
            return "找不到 App 的 Info.plist"
        case .invalidInfoPlist:
            return "Info.plist 格式异常"
        case .commandFailed(let message):
            return message
        }
    }
}

final class IPAPreviewService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func preview(url: URL) throws -> IPAPreviewInfo {
        let pathExtension = url.pathExtension.lowercased()
        if pathExtension == "app" {
            return try previewAppDirectory(url)
        }
        if pathExtension == "ipa" || pathExtension == "zip" {
            return try previewArchive(url)
        }
        throw IPAPreviewError.unsupportedInput
    }
}

private extension IPAPreviewService {
    func previewArchive(_ archiveURL: URL) throws -> IPAPreviewInfo {
        let entries = try listArchiveEntries(archiveURL)
        guard let infoEntry = entries.first(where: { isAppInfoEntry($0) }) else {
            throw IPAPreviewError.missingAppBundle
        }

        let appPrefix = String(infoEntry.dropLast("Info.plist".count))
        let appDirectoryName = appDirectoryName(fromArchivePrefix: appPrefix)
        let info = try appInfo(from: try extractArchiveEntry(infoEntry, from: archiveURL))
        let embeddedProfile = try archiveProvisioningProfile(archiveURL: archiveURL, entries: entries, appPrefix: appPrefix)
        let appexes = try archiveAppexes(archiveURL: archiveURL, entries: entries, appPrefix: appPrefix)
        let iconData = try archiveIconData(archiveURL: archiveURL, entries: entries, appPrefix: appPrefix, info: info)
        let codeSignature = archiveCodeSignature(entries: entries, appPrefix: appPrefix)

        return IPAPreviewInfo(
            fileURL: archiveURL,
            fileName: archiveURL.lastPathComponent,
            fileSize: fileSize(archiveURL),
            appDirectoryName: appDirectoryName,
            appName: displayName(from: info),
            bundleIdentifier: info["CFBundleIdentifier"] as? String ?? "",
            version: info["CFBundleShortVersionString"] as? String ?? "",
            buildVersion: info["CFBundleVersion"] as? String ?? "",
            minimumOSVersion: info["MinimumOSVersion"] as? String,
            executableName: info["CFBundleExecutable"] as? String,
            iconData: iconData,
            codeSignature: codeSignature,
            provisioningProfile: embeddedProfile,
            appexes: appexes,
            frameworks: frameworkNames(in: entries, appPrefix: appPrefix),
            dynamicLibraries: dynamicLibraryNames(in: entries, appPrefix: appPrefix)
        )
    }

    func previewAppDirectory(_ appURL: URL) throws -> IPAPreviewInfo {
        let infoURL = appURL.appendingPathComponent("Info.plist")
        guard fileManager.fileExists(atPath: infoURL.path) else {
            throw IPAPreviewError.missingInfoPlist
        }

        let info = try appInfo(from: Data(contentsOf: infoURL))
        let entries = directoryEntries(appURL)
        let embeddedProfile = try directoryProvisioningProfile(appURL)
        let appexes = try directoryAppexes(appURL)
        let iconData = try directoryIconData(appURL: appURL, entries: entries, info: info)
        let codeSignature = directoryCodeSignature(appURL)

        return IPAPreviewInfo(
            fileURL: appURL,
            fileName: appURL.lastPathComponent,
            fileSize: fileSize(appURL),
            appDirectoryName: appURL.lastPathComponent,
            appName: displayName(from: info),
            bundleIdentifier: info["CFBundleIdentifier"] as? String ?? "",
            version: info["CFBundleShortVersionString"] as? String ?? "",
            buildVersion: info["CFBundleVersion"] as? String ?? "",
            minimumOSVersion: info["MinimumOSVersion"] as? String,
            executableName: info["CFBundleExecutable"] as? String,
            iconData: iconData,
            codeSignature: codeSignature,
            provisioningProfile: embeddedProfile,
            appexes: appexes,
            frameworks: frameworkNames(in: entries, appPrefix: ""),
            dynamicLibraries: dynamicLibraryNames(in: entries, appPrefix: "")
        )
    }

    func appInfo(from data: Data) throws -> [String: Any] {
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw IPAPreviewError.invalidInfoPlist
        }
        return plist
    }

    func displayName(from info: [String: Any]) -> String {
        if let displayName = info["CFBundleDisplayName"] as? String, !displayName.isEmpty {
            return displayName
        }
        if let name = info["CFBundleName"] as? String, !name.isEmpty {
            return name
        }
        return info["CFBundleIdentifier"] as? String ?? ""
    }
}

private extension IPAPreviewService {
    func listArchiveEntries(_ archiveURL: URL) throws -> [String] {
        let data = try runProcess("/usr/bin/unzip", arguments: ["-Z1", archiveURL.path])
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    func extractArchiveEntry(_ entry: String, from archiveURL: URL) throws -> Data {
        try runProcess("/usr/bin/unzip", arguments: ["-p", archiveURL.path, entry])
    }

    func isAppInfoEntry(_ entry: String) -> Bool {
        entry.range(of: #"^Payload/[^/]+\.app/Info\.plist$"#, options: .regularExpression) != nil
    }

    func appDirectoryName(fromArchivePrefix appPrefix: String) -> String {
        appPrefix.split(separator: "/").first(where: { $0.hasSuffix(".app") }).map(String.init) ?? ""
    }

    func archiveAppexes(archiveURL: URL, entries: [String], appPrefix: String) throws -> [IPAPreviewEmbeddedBundle] {
        let infoEntries = entries
            .filter { $0.hasPrefix(appPrefix + "PlugIns/") && $0.hasSuffix(".appex/Info.plist") }
            .sorted()

        return try infoEntries.map { entry in
            let info = try appInfo(from: extractArchiveEntry(entry, from: archiveURL))
            return embeddedBundle(from: info)
        }
    }

    func archiveProvisioningProfile(archiveURL: URL, entries: [String], appPrefix: String) throws -> IPAPreviewProvisioningProfile? {
        let profileEntry = appPrefix + "embedded.mobileprovision"
        guard entries.contains(profileEntry) else {
            return nil
        }
        return try decodeProvisioningProfile(data: extractArchiveEntry(profileEntry, from: archiveURL))
    }

    func archiveIconData(archiveURL: URL, entries: [String], appPrefix: String, info: [String: Any]) throws -> Data? {
        guard let iconEntry = iconEntry(entries: entries, appPrefix: appPrefix, info: info) else {
            return nil
        }
        return try? extractArchiveEntry(iconEntry, from: archiveURL)
    }

    func archiveCodeSignature(entries: [String], appPrefix: String) -> IPAPreviewCodeSignature {
        let codeResources = appPrefix + "_CodeSignature/CodeResources"
        return IPAPreviewCodeSignature(
            hasCodeResources: entries.contains(codeResources),
            codeResourcesPath: entries.contains(codeResources) ? codeResources : nil
        )
    }
}

private extension IPAPreviewService {
    func directoryEntries(_ appURL: URL) -> [String] {
        guard let enumerator = fileManager.enumerator(at: appURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }

        return enumerator.compactMap { item -> String? in
            guard let url = item as? URL else {
                return nil
            }
            return url.path.replacingOccurrences(of: appURL.path + "/", with: "")
        }
    }

    func directoryAppexes(_ appURL: URL) throws -> [IPAPreviewEmbeddedBundle] {
        let plugInsURL = appURL.appendingPathComponent("PlugIns")
        guard let contents = try? fileManager.contentsOfDirectory(at: plugInsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }

        return try contents
            .filter { $0.pathExtension == "appex" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { appexURL in
                let info = try appInfo(from: Data(contentsOf: appexURL.appendingPathComponent("Info.plist")))
                return embeddedBundle(from: info)
            }
    }

    func directoryProvisioningProfile(_ appURL: URL) throws -> IPAPreviewProvisioningProfile? {
        let profileURL = appURL.appendingPathComponent("embedded.mobileprovision")
        guard fileManager.fileExists(atPath: profileURL.path) else {
            return nil
        }
        return try decodeProvisioningProfile(data: Data(contentsOf: profileURL))
    }

    func directoryIconData(appURL: URL, entries: [String], info: [String: Any]) throws -> Data? {
        guard let entry = iconEntry(entries: entries, appPrefix: "", info: info) else {
            return nil
        }
        return try? Data(contentsOf: appURL.appendingPathComponent(entry))
    }

    func directoryCodeSignature(_ appURL: URL) -> IPAPreviewCodeSignature {
        let codeResourcesURL = appURL.appendingPathComponent("_CodeSignature/CodeResources")
        let exists = fileManager.fileExists(atPath: codeResourcesURL.path)
        return IPAPreviewCodeSignature(
            hasCodeResources: exists,
            codeResourcesPath: exists ? codeResourcesURL.path : nil
        )
    }
}

private extension IPAPreviewService {
    func embeddedBundle(from info: [String: Any]) -> IPAPreviewEmbeddedBundle {
        IPAPreviewEmbeddedBundle(
            name: displayName(from: info),
            bundleIdentifier: info["CFBundleIdentifier"] as? String ?? "",
            version: info["CFBundleShortVersionString"] as? String ?? "",
            buildVersion: info["CFBundleVersion"] as? String ?? ""
        )
    }

    func frameworkNames(in entries: [String], appPrefix: String) -> [String] {
        let prefix = appPrefix + "Frameworks/"
        return entries.compactMap { entry -> String? in
            guard entry.hasPrefix(prefix) else {
                return nil
            }
            return entry.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
        }
        .filter { $0.hasSuffix(".framework") }
        .uniqueSorted()
    }

    func dynamicLibraryNames(in entries: [String], appPrefix: String) -> [String] {
        entries.compactMap { entry -> String? in
            guard entry.hasPrefix(appPrefix), entry.hasSuffix(".dylib") else {
                return nil
            }
            return URL(fileURLWithPath: entry).lastPathComponent
        }
        .uniqueSorted()
    }

    func iconEntry(entries: [String], appPrefix: String, info: [String: Any]) -> String? {
        let names = iconBaseNames(from: info)
        guard !names.isEmpty else {
            return nil
        }

        let pngEntries = entries
            .filter { $0.hasPrefix(appPrefix) && $0.lowercased().hasSuffix(".png") }
            .sorted { iconScore($0) > iconScore($1) }

        return pngEntries.first { entry in
            let baseName = URL(fileURLWithPath: entry).deletingPathExtension().lastPathComponent
            return names.contains { baseName == $0 || baseName.hasPrefix($0 + "@") }
        }
    }

    func iconBaseNames(from info: [String: Any]) -> [String] {
        var names: [String] = []
        if let iconName = info["CFBundleIconName"] as? String {
            names.append(iconName)
        }
        if let icons = info["CFBundleIcons"] as? [String: Any],
           let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any] {
            names.append(contentsOf: primaryIcon["CFBundleIconFiles"] as? [String] ?? [])
            if let iconName = primaryIcon["CFBundleIconName"] as? String {
                names.append(iconName)
            }
        }
        return names.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }.uniqueSorted()
    }

    func iconScore(_ entry: String) -> Int {
        let name = URL(fileURLWithPath: entry).lastPathComponent
        if name.contains("@3x") {
            return 3
        }
        if name.contains("@2x") {
            return 2
        }
        return 1
    }

    func decodeProvisioningProfile(data: Data) throws -> IPAPreviewProvisioningProfile? {
        let plistData = decodedProvisioningPlistData(from: data) ?? data
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        let teamIdentifier = (plist["TeamIdentifier"] as? [String])?.first ?? ""
        let provisionedDevices = plist["ProvisionedDevices"] as? [String]
        let provisionsAllDevices = plist["ProvisionsAllDevices"] as? Bool ?? false
        let getTaskAllow = entitlements["get-task-allow"] as? Bool
        let profileType = profileType(
            provisionsAllDevices: provisionsAllDevices,
            provisionedDevices: provisionedDevices,
            getTaskAllow: getTaskAllow
        )

        return IPAPreviewProvisioningProfile(
            name: plist["Name"] as? String ?? "",
            uuid: plist["UUID"] as? String ?? "",
            teamName: plist["TeamName"] as? String ?? "",
            teamIdentifier: teamIdentifier,
            applicationIdentifier: entitlements["application-identifier"] as? String ?? "",
            profileType: profileType,
            creationDate: plist["CreationDate"] as? Date,
            expirationDate: plist["ExpirationDate"] as? Date,
            provisionedDeviceCount: provisionedDevices?.count ?? 0,
            provisionsAllDevices: provisionsAllDevices,
            apsEnvironment: entitlements["aps-environment"] as? String,
            getTaskAllow: getTaskAllow,
            entitlementKeys: entitlements.keys.sorted(),
            certificates: (plist["DeveloperCertificates"] as? [Data] ?? []).compactMap(certificateInfo(from:))
        )
    }

    func decodedProvisioningPlistData(from data: Data) -> Data? {
        let tempURL = fileManager.temporaryDirectory.appendingPathComponent("easysign-\(UUID().uuidString).mobileprovision")
        guard (try? data.write(to: tempURL)) != nil else {
            return nil
        }
        defer { try? fileManager.removeItem(at: tempURL) }

        return try? runProcess("/usr/bin/security", arguments: ["cms", "-D", "-i", tempURL.path])
    }

    func profileType(provisionsAllDevices: Bool, provisionedDevices: [String]?, getTaskAllow: Bool?) -> String {
        if provisionsAllDevices {
            return "Enterprise"
        }
        if let provisionedDevices, !provisionedDevices.isEmpty {
            return getTaskAllow == true ? "Development" : "Ad Hoc"
        }
        return "App Store"
    }

    func certificateInfo(from data: Data) -> IPAPreviewCertificate? {
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            return nil
        }

        var commonName: CFString?
        SecCertificateCopyCommonName(certificate, &commonName)
        let der = SecCertificateCopyData(certificate) as Data
        return IPAPreviewCertificate(
            commonName: commonName as String? ?? certificateSummary(certificate),
            organization: certificateSubjectValue(certificate, oid: kSecOIDOrganizationName),
            teamIdentifier: certificateSubjectValue(certificate, oid: kSecOIDOrganizationalUnitName),
            countryName: certificateSubjectValue(certificate, oid: kSecOIDCountryName),
            notBefore: certificateDate(certificate, oid: kSecOIDX509V1ValidityNotBefore),
            notAfter: certificateDate(certificate, oid: kSecOIDX509V1ValidityNotAfter),
            sha1Fingerprint: sha1Fingerprint(der)
        )
    }

    func certificateSummary(_ certificate: SecCertificate) -> String {
        SecCertificateCopySubjectSummary(certificate) as String? ?? ""
    }

    func certificateSubjectValue(_ certificate: SecCertificate, oid: CFString) -> String {
        guard let result = SecCertificateCopyValues(certificate, [kSecOIDX509V1SubjectName] as CFArray, nil) as? [CFString: [CFString: Any]],
              let subject = result[kSecOIDX509V1SubjectName],
              let subjectItems = subject[kSecPropertyKeyValue] as? [[CFString: Any]]
        else {
            return ""
        }

        for item in subjectItems {
            guard let rawLabel = item[kSecPropertyKeyLabel] else {
                continue
            }
            let label = rawLabel as! CFString
            if CFEqual(label, oid), let value = item[kSecPropertyKeyValue] {
                return "\(value)"
            }
        }
        return ""
    }

    func certificateDate(_ certificate: SecCertificate, oid: CFString) -> Date? {
        guard let result = SecCertificateCopyValues(certificate, [oid] as CFArray, nil) as? [CFString: [CFString: Any]],
              let dict = result[oid],
              let value = dict[kSecPropertyKeyValue]
        else {
            return nil
        }
        if let date = value as? Date {
            return date
        }
        if let number = value as? NSNumber,
           let sinceDate = DateComponents(calendar: Calendar.current, timeZone: TimeZone(secondsFromGMT: 0), year: 2001).date {
            return Date(timeInterval: number.doubleValue, since: sinceDate)
        }
        return nil
    }

    func sha1Fingerprint(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }

    func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    func runProcess(_ executable: String, arguments: [String]) throws -> Data {
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus == 0 {
            return output
        }

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        throw IPAPreviewError.commandFailed(message?.isEmpty == false ? message! : "\(executable) 执行失败")
    }
}

private extension Sequence where Element: Hashable & Comparable {
    func uniqueSorted() -> [Element] {
        Array(Set(self)).sorted()
    }
}
