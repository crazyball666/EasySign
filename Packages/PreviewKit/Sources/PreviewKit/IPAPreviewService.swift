//
//  IPAPreviewService.swift
//  EasySign
//

import Compression
import CryptoKit
import Foundation
import Security
#if DEBUG
import os
#endif

public struct IPAPreviewEmbeddedBundle: Identifiable, Equatable {
    public var id: String { bundleIdentifier }
    public let name: String
    public let bundleIdentifier: String
    public let version: String
    public let buildVersion: String
}

public struct IPAPreviewProvisioningProfile: Equatable {
    public let name: String
    public let uuid: String
    public let teamName: String
    public let teamIdentifier: String
    public let applicationIdentifier: String
    public let profileType: String
    public let creationDate: Date?
    public let expirationDate: Date?
    public let provisionedDeviceCount: Int
    public let provisionedDevices: [String]
    public let provisionsAllDevices: Bool
    public let apsEnvironment: String?
    public let getTaskAllow: Bool?
    public let entitlementKeys: [String]
    /// 完整 entitlements 键值(递归格式化成 "key = value" 行,dict/array 带缩进)
    public let entitlementLines: [String]
    public let certificates: [IPAPreviewCertificate]
}

/// 独立预览一个 .mobileprovision / .provisionprofile 文件时的结果
public struct IPAPreviewProfileFile {
    public let fileURL: URL
    public let fileName: String
    public let fileSize: Int64
    public let profile: IPAPreviewProvisioningProfile
}

public enum IPAPreviewResult {
    case app(IPAPreviewInfo)
    case provisioningProfile(IPAPreviewProfileFile)
}

public struct IPAPreviewCertificate: Identifiable, Equatable {
    public var id: String { sha1Fingerprint.isEmpty ? commonName : sha1Fingerprint }
    public let commonName: String
    public let organization: String
    public let teamIdentifier: String
    public let countryName: String
    public let notBefore: Date?
    public let notAfter: Date?
    public let sha1Fingerprint: String
}

public struct IPAPreviewCodeSignature: Equatable {
    public let hasCodeResources: Bool
    public let codeResourcesPath: String?
}

public struct IPAPreviewInfo: Identifiable {
    public var id: String { fileURL.path }
    public let fileURL: URL
    public let fileName: String
    public let fileSize: Int64
    public let appDirectoryName: String
    public let appName: String
    public let bundleIdentifier: String
    public let version: String
    public let buildVersion: String
    public let minimumOSVersion: String?
    public let executableName: String?
    public let iconData: Data?
    public let codeSignature: IPAPreviewCodeSignature
    public let provisioningProfile: IPAPreviewProvisioningProfile?
    /// 主可执行文件里实际签入的 entitlements(区别于描述文件声明);未签名/解析失败为空
    public let appEntitlementLines: [String]
    public let appexes: [IPAPreviewEmbeddedBundle]
    public let frameworks: [String]
    public let dynamicLibraries: [String]

    public var versionDescription: String {
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

    public var signingDescription: String {
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

/// 证书/描述文件的有效性状态。供 UI 用。
public enum ValidityStatus: Equatable {
    case notYetValid
    case valid
    case expiringSoon   // 30 天内
    case expired

    public var label: String {
        switch self {
        case .notYetValid:  return "未生效"
        case .valid:        return "有效"
        case .expiringSoon: return "即将过期"
        case .expired:      return "已过期"
        }
    }

    /// macOS HIG 风格调色：绿/橙/红
    public var color: String {
        switch self {
        case .notYetValid:  return "systemYellow"
        case .valid:        return "systemGreen"
        case .expiringSoon: return "systemOrange"
        case .expired:      return "systemRed"
        }
    }
}

extension IPAPreviewCertificate {
    public var validityStatus: ValidityStatus {
        guard let notBefore, let notAfter else { return .valid }  // 无法判断时按"未知"显示
        let now = Date()
        if now < notBefore { return .notYetValid }
        if now > notAfter { return .expired }
        let days = notAfter.timeIntervalSince(now) / 86400
        if days <= 30 { return .expiringSoon }
        return .valid
    }

    /// 距离过期还有多少天（负数表示已过期多少天）
    public var daysUntilExpiry: Int? {
        guard let notAfter else { return nil }
        let now = Date()
        return Int(notAfter.timeIntervalSince(now) / 86400)
    }
}

extension IPAPreviewProvisioningProfile {
    public var validityStatus: ValidityStatus {
        guard let expirationDate else { return .valid }
        let now = Date()
        if let creationDate, now < creationDate { return .notYetValid }
        if now > expirationDate { return .expired }
        let days = expirationDate.timeIntervalSince(now) / 86400
        if days <= 30 { return .expiringSoon }
        return .valid
    }

    public var daysUntilExpiry: Int? {
        guard let expirationDate else { return nil }
        return Int(expirationDate.timeIntervalSince(Date()) / 86400)
    }
}

public enum IPAPreviewError: LocalizedError {
    case unsupportedInput
    case missingAppBundle
    case missingInfoPlist
    case invalidInfoPlist
    case invalidArchive
    case missingArchiveEntry(String)
    case unsupportedCompressionMethod(UInt16)
    case invalidProvisioningProfile
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedInput:
            return "仅支持预览 .ipa、.zip、.app 或 .mobileprovision"
        case .missingAppBundle:
            return "找不到 Payload 里的 .app"
        case .missingInfoPlist:
            return "找不到 App 的 Info.plist"
        case .invalidInfoPlist:
            return "Info.plist 格式异常"
        case .invalidArchive:
            return "IPA/ZIP 文件结构异常"
        case .missingArchiveEntry(let entry):
            return "IPA/ZIP 中找不到 \(entry)"
        case .unsupportedCompressionMethod(let method):
            return "暂不支持 ZIP 压缩方式 \(method)"
        case .invalidProvisioningProfile:
            return "描述文件格式异常,无法解析"
        case .commandFailed(let message):
            return message
        }
    }
}

public final class IPAPreviewService {
    /// 为读取 entitlements 而整块解压/读入可执行文件的大小上限(约 200MB)。
    /// 超过则跳过 App Entitlements,避免在内存受限的预览/缩略图扩展里被 jetsam。
    static let maxExecutableBytesForEntitlements: UInt64 = 200 * 1024 * 1024

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// includeAppEntitlements:是否读取主可执行文件并解析签入的 entitlements。
    /// 可执行文件可能上百 MB,只要图标的场景(缩略图)应传 false。
    public func preview(url: URL, includeAppEntitlements: Bool = true) throws -> IPAPreviewInfo {
        let pathExtension = url.pathExtension.lowercased()
        if pathExtension == "app" {
            return try previewAppDirectory(url, includeAppEntitlements: includeAppEntitlements)
        }
        if pathExtension == "ipa" || pathExtension == "zip" {
            return try previewArchive(url, includeAppEntitlements: includeAppEntitlements)
        }
        throw IPAPreviewError.unsupportedInput
    }

    /// 统一入口:除 IPA/app 外还支持独立的 .mobileprovision / .provisionprofile
    public func previewFile(url: URL) throws -> IPAPreviewResult {
        let pathExtension = url.pathExtension.lowercased()
        if pathExtension == "mobileprovision" || pathExtension == "provisionprofile" {
            return .provisioningProfile(try previewProvisioningProfileFile(url))
        }
        return .app(try preview(url: url))
    }

    public func previewProvisioningProfileFile(_ url: URL) throws -> IPAPreviewProfileFile {
        guard let profile = try decodeProvisioningProfile(data: Data(contentsOf: url)) else {
            throw IPAPreviewError.invalidProvisioningProfile
        }
        return IPAPreviewProfileFile(
            fileURL: url,
            fileName: url.lastPathComponent,
            fileSize: fileSize(url),
            profile: profile
        )
    }
}

private struct IPAPreviewTiming {
#if DEBUG
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EasySign",
        category: "IPAPreview"
    )

    private let fileName: String
    private let startTime: CFAbsoluteTime
    private var lastStepTime: CFAbsoluteTime
#endif

    init(fileName: String) {
#if DEBUG
        self.fileName = fileName
        let now = CFAbsoluteTimeGetCurrent()
        startTime = now
        lastStepTime = now
#endif
    }

    mutating func step(_ name: String) {
#if DEBUG
        let now = CFAbsoluteTimeGetCurrent()
        let totalMilliseconds = (now - startTime) * 1000
        let stepMilliseconds = (now - lastStepTime) * 1000
        lastStepTime = now
        let currentFileName = fileName
        Self.logger.debug("\(currentFileName, privacy: .public) \(name, privacy: .public) total=\(totalMilliseconds, format: .fixed(precision: 1))ms step=\(stepMilliseconds, format: .fixed(precision: 1))ms")
#endif
    }
}

private struct IPAPreviewArchiveEntries {
    let infoEntry: String
    let appDirectoryName: String
    let profileEntry: String?
    let codeResourcesPath: String?
    let appexInfoEntries: [String]
    let pngEntries: [String]
    let frameworks: [String]
    let dynamicLibraries: [String]
}

private extension IPAPreviewService {
    func previewArchive(_ archiveURL: URL, includeAppEntitlements: Bool) throws -> IPAPreviewInfo {
        var timing = IPAPreviewTiming(fileName: archiveURL.lastPathComponent)
        let archive = try ZIPArchiveReader(url: archiveURL)
        timing.step("loadEntries")

        let archiveEntries = try archiveEntries(from: archive)
        timing.step("indexEntries")

        let info = try appInfo(from: try archive.data(for: archiveEntries.infoEntry))
        timing.step("readInfoPlist")

        let embeddedProfile = try archiveProvisioningProfile(archive: archive, profileEntry: archiveEntries.profileEntry)
        timing.step("decodeProvisioningProfile")

        var appEntitlementLines: [String] = []
        if includeAppEntitlements, let executableName = info["CFBundleExecutable"] as? String {
            let executableEntry = "Payload/\(archiveEntries.appDirectoryName)/\(executableName)"
            // 只读 entitlements 却要整块解压可执行文件;对超大(含 zip 炸弹)条目设上限,
            // 避免在内存受限的 QuickLook 扩展里 OOM 被 jetsam。
            let size = archive.uncompressedSize(for: executableEntry) ?? 0
            if size > 0, size <= Self.maxExecutableBytesForEntitlements,
               let executableData = try? archive.data(for: executableEntry) {
                appEntitlementLines = MachOEntitlementsReader.entitlementLines(fromExecutable: executableData)
            }
        }
        timing.step("readMachOEntitlements")

        let appexes = try archiveAppexes(archive: archive, infoEntries: archiveEntries.appexInfoEntries)
        timing.step("readAppexInfo")

        let iconData = try archiveIconData(archive: archive, pngEntries: archiveEntries.pngEntries, info: info)
        timing.step("readIcon")

        let codeSignature = archiveCodeSignature(codeResourcesPath: archiveEntries.codeResourcesPath)
        timing.step("buildPreview")

        return IPAPreviewInfo(
            fileURL: archiveURL,
            fileName: archiveURL.lastPathComponent,
            fileSize: fileSize(archiveURL),
            appDirectoryName: archiveEntries.appDirectoryName,
            appName: displayName(from: info),
            bundleIdentifier: info["CFBundleIdentifier"] as? String ?? "",
            version: info["CFBundleShortVersionString"] as? String ?? "",
            buildVersion: info["CFBundleVersion"] as? String ?? "",
            minimumOSVersion: info["MinimumOSVersion"] as? String,
            executableName: info["CFBundleExecutable"] as? String,
            iconData: iconData,
            codeSignature: codeSignature,
            provisioningProfile: embeddedProfile,
            appEntitlementLines: appEntitlementLines,
            appexes: appexes,
            frameworks: archiveEntries.frameworks,
            dynamicLibraries: archiveEntries.dynamicLibraries
        )
    }

    func previewAppDirectory(_ appURL: URL, includeAppEntitlements: Bool) throws -> IPAPreviewInfo {
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

        var appEntitlementLines: [String] = []
        if includeAppEntitlements, let executableName = info["CFBundleExecutable"] as? String {
            let executableURL = appURL.appendingPathComponent(executableName)
            let size = (try? executableURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
            if size > 0, size <= Self.maxExecutableBytesForEntitlements,
               let executableData = try? Data(contentsOf: executableURL) {
                appEntitlementLines = MachOEntitlementsReader.entitlementLines(fromExecutable: executableData)
            }
        }

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
            appEntitlementLines: appEntitlementLines,
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
    func isAppInfoEntry(_ entry: String) -> Bool {
        entry.range(of: #"^Payload/[^/]+\.app/Info\.plist$"#, options: .regularExpression) != nil
    }

    func appDirectoryName(fromArchivePrefix appPrefix: String) -> String {
        appPrefix.split(separator: "/").first(where: { $0.hasSuffix(".app") }).map(String.init) ?? ""
    }

    func archiveEntries(from archive: ZIPArchiveReader) throws -> IPAPreviewArchiveEntries {
        guard let infoEntry = archive.firstEntryName(where: isAppInfoEntry) else {
            throw IPAPreviewError.missingAppBundle
        }

        let appPrefix = String(infoEntry.dropLast("Info.plist".count))
        let profilePath = appPrefix + "embedded.mobileprovision"
        let codeResourcesPath = appPrefix + "_CodeSignature/CodeResources"
        let plugInsPrefix = appPrefix + "PlugIns/"
        let frameworksPrefix = appPrefix + "Frameworks/"

        var profileEntry: String?
        var codeResourcesEntry: String?
        var appexInfoEntries: [String] = []
        var pngEntries: [String] = []
        var frameworkNames = Set<String>()
        var dylibNames = Set<String>()

        archive.forEachEntryName { entry in
            guard entry.hasPrefix(appPrefix) else {
                return
            }

            if entry == profilePath {
                profileEntry = entry
            }
            if entry == codeResourcesPath {
                codeResourcesEntry = entry
            }
            if entry.hasPrefix(plugInsPrefix), entry.hasSuffix(".appex/Info.plist") {
                appexInfoEntries.append(entry)
            }
            if entry.hasPrefix(frameworksPrefix),
               let frameworkName = entry.dropFirst(frameworksPrefix.count).split(separator: "/").first.map(String.init),
               frameworkName.hasSuffix(".framework") {
                frameworkNames.insert(frameworkName)
            }
            if entry.hasSuffix(".dylib") {
                dylibNames.insert(URL(fileURLWithPath: entry).lastPathComponent)
            }
            if entry.lowercased().hasSuffix(".png") {
                pngEntries.append(entry)
            }
        }

        return IPAPreviewArchiveEntries(
            infoEntry: infoEntry,
            appDirectoryName: appDirectoryName(fromArchivePrefix: appPrefix),
            profileEntry: profileEntry,
            codeResourcesPath: codeResourcesEntry,
            appexInfoEntries: appexInfoEntries.sorted(),
            pngEntries: pngEntries,
            frameworks: frameworkNames.sorted(),
            dynamicLibraries: dylibNames.sorted()
        )
    }

    func archiveAppexes(archive: ZIPArchiveReader, infoEntries: [String]) throws -> [IPAPreviewEmbeddedBundle] {
        return try infoEntries.map { entry in
            let info = try appInfo(from: archive.data(for: entry))
            return embeddedBundle(from: info)
        }
    }

    func archiveProvisioningProfile(archive: ZIPArchiveReader, profileEntry: String?) throws -> IPAPreviewProvisioningProfile? {
        guard let profileEntry else {
            return nil
        }
        return try decodeProvisioningProfile(data: archive.data(for: profileEntry))
    }

    func archiveIconData(archive: ZIPArchiveReader, pngEntries: [String], info: [String: Any]) throws -> Data? {
        guard let iconEntry = iconEntry(pngEntries: pngEntries, info: info) else {
            return nil
        }
        return try? archive.data(for: iconEntry)
    }

    func archiveCodeSignature(codeResourcesPath: String?) -> IPAPreviewCodeSignature {
        return IPAPreviewCodeSignature(
            hasCodeResources: codeResourcesPath != nil,
            codeResourcesPath: codeResourcesPath
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
        iconEntry(
            pngEntries: entries.filter { $0.hasPrefix(appPrefix) && $0.lowercased().hasSuffix(".png") },
            info: info
        )
    }

    func iconEntry(pngEntries: [String], info: [String: Any]) -> String? {
        let names = iconBaseNames(from: info)
        guard !names.isEmpty else {
            return nil
        }

        var bestEntry: String?
        var bestScore = 0

        for entry in pngEntries {
            let baseName = URL(fileURLWithPath: entry).deletingPathExtension().lastPathComponent
            guard names.contains(where: { baseName == $0 || baseName.hasPrefix($0 + "@") }) else {
                continue
            }

            let score = iconScore(entry)
            if score > bestScore {
                bestEntry = entry
                bestScore = score
            }
        }

        return bestEntry
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
            provisionedDevices: provisionedDevices?.sorted() ?? [],
            provisionsAllDevices: provisionsAllDevices,
            apsEnvironment: entitlements["aps-environment"] as? String,
            getTaskAllow: getTaskAllow,
            entitlementKeys: entitlements.keys.sorted(),
            entitlementLines: IPAPreviewPlistFormatter.lines(from: entitlements),
            certificates: (plist["DeveloperCertificates"] as? [Data] ?? []).compactMap(certificateInfo(from:))
        )
    }

    func decodedProvisioningPlistData(from data: Data) -> Data? {
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else {
            return nil
        }
        let updateStatus = data.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else {
                return errSecParam
            }
            return CMSDecoderUpdateMessage(decoder, baseAddress, data.count)
        }
        guard updateStatus == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess
        else {
            return nil
        }

        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content else {
            return nil
        }
        return content as Data
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
        let values = certificateValues(certificate)
        let subjectValues = certificateSubjectValues(from: values)
        let der = SecCertificateCopyData(certificate) as Data
        return IPAPreviewCertificate(
            commonName: commonName as String? ?? certificateSummary(certificate),
            organization: subjectValue(subjectValues, oid: kSecOIDOrganizationName),
            teamIdentifier: subjectValue(subjectValues, oid: kSecOIDOrganizationalUnitName),
            countryName: subjectValue(subjectValues, oid: kSecOIDCountryName),
            notBefore: certificateDate(from: values, oid: kSecOIDX509V1ValidityNotBefore),
            notAfter: certificateDate(from: values, oid: kSecOIDX509V1ValidityNotAfter),
            sha1Fingerprint: sha1Fingerprint(der)
        )
    }

    func certificateSummary(_ certificate: SecCertificate) -> String {
        SecCertificateCopySubjectSummary(certificate) as String? ?? ""
    }

    func certificateValues(_ certificate: SecCertificate) -> [CFString: [CFString: Any]] {
        let keys: [CFString] = [
            kSecOIDX509V1SubjectName,
            kSecOIDX509V1ValidityNotBefore,
            kSecOIDX509V1ValidityNotAfter
        ]
        return SecCertificateCopyValues(certificate, keys as CFArray, nil) as? [CFString: [CFString: Any]] ?? [:]
    }

    func certificateSubjectValues(from result: [CFString: [CFString: Any]]) -> [String: String] {
        guard let subject = result[kSecOIDX509V1SubjectName],
              let subjectItems = subject[kSecPropertyKeyValue] as? [[CFString: Any]]
        else {
            return [:]
        }

        var values: [String: String] = [:]
        for item in subjectItems {
            guard let rawLabel = item[kSecPropertyKeyLabel] as? String,
                  let value = item[kSecPropertyKeyValue]
            else {
                continue
            }
            values[rawLabel] = "\(value)"
        }
        return values
    }

    func subjectValue(_ values: [String: String], oid: CFString) -> String {
        values[oid as String] ?? ""
    }

    func certificateDate(from result: [CFString: [CFString: Any]], oid: CFString) -> Date? {
        guard let dict = result[oid],
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

}

private final class ZIPArchiveReader {
    private struct Entry {
        let name: String
        let flags: UInt16
        let compressionMethod: UInt16
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
    }

    private let fileHandle: FileHandle
    private let archiveSize: UInt64
    private let entriesByName: [String: Entry]

    init(url: URL) throws {
        fileHandle = try FileHandle(forReadingFrom: url)
        archiveSize = UInt64((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let loadedEntries = try ZIPArchiveReader.loadEntries(fileHandle: fileHandle, archiveSize: archiveSize)

        var indexedEntries: [String: Entry] = [:]
        indexedEntries.reserveCapacity(loadedEntries.count)
        for entry in loadedEntries where indexedEntries[entry.name] == nil {
            indexedEntries[entry.name] = entry
        }
        entriesByName = indexedEntries
    }

    deinit {
        try? fileHandle.close()
    }

    func firstEntryName(where predicate: (String) -> Bool) -> String? {
        entriesByName.keys.first(where: predicate)
    }

    func forEachEntryName(_ body: (String) -> Void) {
        for name in entriesByName.keys {
            body(name)
        }
    }

    /// 条目解压后的大小(不读取内容),用于在解压前对超大条目做防护
    func uncompressedSize(for name: String) -> UInt64? {
        entriesByName[name]?.uncompressedSize
    }

    func data(for name: String) throws -> Data {
        guard let entry = entriesByName[name] else {
            throw IPAPreviewError.missingArchiveEntry(name)
        }
        guard entry.flags & 0x0001 == 0 else {
            throw IPAPreviewError.invalidArchive
        }

        let localHeader = try readData(offset: entry.localHeaderOffset, length: 30)
        guard localHeader.zipUInt32(at: 0) == 0x04034b50 else {
            throw IPAPreviewError.invalidArchive
        }

        let fileNameLength = UInt64(localHeader.zipUInt16(at: 26))
        let extraFieldLength = UInt64(localHeader.zipUInt16(at: 28))
        let dataOffset = entry.localHeaderOffset + 30 + fileNameLength + extraFieldLength
        let compressedData = try readData(offset: dataOffset, length: entry.compressedSize)

        switch entry.compressionMethod {
        case 0:
            return compressedData
        case 8:
            return try inflate(compressedData, expectedSize: entry.uncompressedSize)
        default:
            throw IPAPreviewError.unsupportedCompressionMethod(entry.compressionMethod)
        }
    }
}

private extension ZIPArchiveReader {
    private static func loadEntries(fileHandle: FileHandle, archiveSize: UInt64) throws -> [Entry] {
        let (centralDirectoryOffset, centralDirectorySize, totalEntries) = try centralDirectoryLocation(
            fileHandle: fileHandle,
            archiveSize: archiveSize
        )
        let centralDirectory = try readData(
            fileHandle: fileHandle,
            offset: centralDirectoryOffset,
            length: centralDirectorySize
        )

        var cursor = 0
        var result: [Entry] = []
        result.reserveCapacity(totalEntries)

        for _ in 0..<totalEntries {
            guard centralDirectory.canRead(offset: cursor, length: 46),
                  centralDirectory.zipUInt32(at: cursor) == 0x02014b50
            else {
                throw IPAPreviewError.invalidArchive
            }

            let flags = centralDirectory.zipUInt16(at: cursor + 8)
            let compressionMethod = centralDirectory.zipUInt16(at: cursor + 10)
            let compressedSize = UInt64(centralDirectory.zipUInt32(at: cursor + 20))
            let uncompressedSize = UInt64(centralDirectory.zipUInt32(at: cursor + 24))
            let fileNameLength = Int(centralDirectory.zipUInt16(at: cursor + 28))
            let extraFieldLength = Int(centralDirectory.zipUInt16(at: cursor + 30))
            let commentLength = Int(centralDirectory.zipUInt16(at: cursor + 32))
            let localHeaderOffset = UInt64(centralDirectory.zipUInt32(at: cursor + 42))
            let fileNameOffset = cursor + 46
            let headerLength = 46 + fileNameLength + extraFieldLength + commentLength

            guard compressedSize < 0xffffffff,
                  uncompressedSize < 0xffffffff,
                  localHeaderOffset < 0xffffffff,
                  centralDirectory.canRead(offset: cursor, length: headerLength)
            else {
                throw IPAPreviewError.invalidArchive
            }

            let fileName = centralDirectory.withUnsafeBytes { rawBuffer -> String in
                let bytes = rawBuffer.bindMemory(to: UInt8.self)
                return String(decoding: bytes[fileNameOffset..<(fileNameOffset + fileNameLength)], as: UTF8.self)
            }
            result.append(Entry(
                name: fileName,
                flags: flags,
                compressionMethod: compressionMethod,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            ))
            cursor += headerLength
        }

        return result
    }

    static func centralDirectoryLocation(
        fileHandle: FileHandle,
        archiveSize: UInt64
    ) throws -> (offset: UInt64, size: UInt64, totalEntries: Int) {
        let maxCommentLength = UInt64(UInt16.max)
        let endRecordLength: UInt64 = 22
        let tailLength = min(archiveSize, maxCommentLength + endRecordLength)
        let tail = try readData(fileHandle: fileHandle, offset: archiveSize - tailLength, length: tailLength)

        guard tail.count >= Int(endRecordLength) else {
            throw IPAPreviewError.invalidArchive
        }

        var cursor = tail.count - Int(endRecordLength)
        while cursor >= 0 {
            if tail.zipUInt32(at: cursor) == 0x06054b50 {
                let commentLength = Int(tail.zipUInt16(at: cursor + 20))
                if cursor + Int(endRecordLength) + commentLength == tail.count {
                    let diskNumber = tail.zipUInt16(at: cursor + 4)
                    let centralDirectoryDisk = tail.zipUInt16(at: cursor + 6)
                    let totalEntries = tail.zipUInt16(at: cursor + 10)
                    let centralDirectorySize = tail.zipUInt32(at: cursor + 12)
                    let centralDirectoryOffset = tail.zipUInt32(at: cursor + 16)

                    guard diskNumber == 0,
                          centralDirectoryDisk == 0,
                          totalEntries < 0xffff,
                          centralDirectorySize < 0xffffffff,
                          centralDirectoryOffset < 0xffffffff
                    else {
                        throw IPAPreviewError.invalidArchive
                    }

                    return (
                        UInt64(centralDirectoryOffset),
                        UInt64(centralDirectorySize),
                        Int(totalEntries)
                    )
                }
            }

            if cursor == 0 {
                break
            }
            cursor -= 1
        }

        throw IPAPreviewError.invalidArchive
    }

    func readData(offset: UInt64, length: UInt64) throws -> Data {
        try Self.readData(fileHandle: fileHandle, offset: offset, length: length)
    }

    static func readData(fileHandle: FileHandle, offset: UInt64, length: UInt64) throws -> Data {
        guard length <= UInt64(Int.max) else {
            throw IPAPreviewError.invalidArchive
        }

        try fileHandle.seek(toOffset: offset)
        guard let data = try fileHandle.read(upToCount: Int(length)),
              data.count == Int(length)
        else {
            throw IPAPreviewError.invalidArchive
        }
        return data
    }

    func inflate(_ data: Data, expectedSize: UInt64) throws -> Data {
        guard expectedSize <= UInt64(Int.max) else {
            throw IPAPreviewError.invalidArchive
        }

        let outputSize = Int(expectedSize)
        guard outputSize > 0 else {
            return Data()
        }

        var output = Data(count: outputSize)
        let decodedSize = output.withUnsafeMutableBytes { outputBuffer -> Int in
            data.withUnsafeBytes { inputBuffer -> Int in
                guard let outputBase = outputBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let inputBase = inputBuffer.bindMemory(to: UInt8.self).baseAddress
                else {
                    return 0
                }

                return compression_decode_buffer(
                    outputBase,
                    outputSize,
                    inputBase,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard decodedSize == outputSize else {
            throw IPAPreviewError.invalidArchive
        }

        return output
    }
}

private extension Data {
    func canRead(offset: Int, length: Int) -> Bool {
        offset >= 0 && length >= 0 && offset + length <= count
    }

    func zipUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) |
            (UInt16(self[offset + 1]) << 8)
    }

    func zipUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }
}

private extension Sequence where Element: Hashable & Comparable {
    func uniqueSorted() -> [Element] {
        Array(Set(self)).sorted()
    }
}

/// 把 plist 字典递归格式化成 "key = value" 的可读行(等宽字体展示用),
/// entitlements(描述文件里的和 Mach-O 里签入的)都走这里。
enum IPAPreviewPlistFormatter {
    /// 递归深度上限:entitlements plist 来自被预览文件(不可信输入),
    /// 恶意构造的深层嵌套会撑爆调用栈,超过此深度直接截断显示。
    private static let maxDepth = 32
    private static let iso8601 = ISO8601DateFormatter()

    static func lines(from dictionary: [String: Any]) -> [String] {
        dictionary.keys.sorted().flatMap { key -> [String] in
            "\(key) = \(format(dictionary[key] as Any, indentationLevel: 0))"
                .components(separatedBy: "\n")
        }
    }

    private static func format(_ value: Any, indentationLevel: Int) -> String {
        guard indentationLevel < maxDepth else {
            return "…"
        }
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            // plist 的 Bool 反序列化成 CFBoolean;不先区分会把 true 显示成 1
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        case let date as Date:
            return iso8601.string(from: date)
        case let data as Data:
            return "<\(data.count) bytes>"
        case let array as [Any]:
            guard !array.isEmpty else {
                return "()"
            }
            let nextIndent = indentation(level: indentationLevel + 1)
            let items = array
                .map { "\(nextIndent)\(format($0, indentationLevel: indentationLevel + 1))" }
                .joined(separator: "\n")
            return "(\n\(items)\n\(indentation(level: indentationLevel)))"
        case let dictionary as [String: Any]:
            guard !dictionary.isEmpty else {
                return "{}"
            }
            let nextIndent = indentation(level: indentationLevel + 1)
            let items = dictionary.keys.sorted()
                .map { "\(nextIndent)\($0) = \(format(dictionary[$0] as Any, indentationLevel: indentationLevel + 1))" }
                .joined(separator: "\n")
            return "{\n\(items)\n\(indentation(level: indentationLevel))}"
        default:
            return "\(value)"
        }
    }

    private static func indentation(level: Int) -> String {
        String(repeating: "    ", count: level)
    }
}
