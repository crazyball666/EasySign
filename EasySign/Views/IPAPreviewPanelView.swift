//
//  IPAPreviewPanelView.swift
//  EasySign
//

import SwiftUI

struct IPAPreviewPanelView: View {
    let info: IPAPreviewInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    previewSection("基础信息") {
                        previewRow("文件", info.fileName)
                        previewRow("App 目录", info.appDirectoryName)
                        previewRow("Bundle ID", info.bundleIdentifier)
                        previewRow("版本", info.versionDescription)
                        previewRow("最低系统", info.minimumOSVersion ?? "-")
                        previewRow("可执行文件", info.executableName ?? "-")
                    }

                    previewSection("签名信息") {
                        previewRow("签名状态", info.signingDescription)
                        previewRow("CodeResources", info.codeSignature.codeResourcesPath ?? "未发现")
                    }

                    if let profile = info.provisioningProfile {
                        previewSection("描述文件") {
                            profileBadges(profile)
                            previewRow("名称", profile.name)
                            previewRow("类型", profile.profileType)
                            previewRow("UUID", profile.uuid)
                            previewRow("Team Name", profile.teamName)
                            previewRow("Team ID", profile.teamIdentifier)
                            previewRow("App ID", profile.applicationIdentifier)
                            previewRow("创建时间", profile.creationDate?.formatString(format: "yyyy-MM-dd HH:mm:ss") ?? "-")
                            previewRow("过期时间", profile.expirationDate?.formatString(format: "yyyy-MM-dd HH:mm:ss") ?? "-")
                            previewRow("过期状态", profile.expirationDate.map(expirationStatus) ?? "-")
                            previewRow("设备数", profile.provisionsAllDevices ? "全部设备" : "\(profile.provisionedDeviceCount)")
                            previewRow("证书数", "\(profile.certificates.count)")
                            previewRow("Entitlements", "\(profile.entitlementKeys.count)")
                            previewRow("APS", profile.apsEnvironment ?? "-")
                            previewRow("调试权限", profile.getTaskAllow.map { $0 ? "YES" : "NO" } ?? "-")
                        }

                        previewListSection("设备列表", values: deviceValues(profile), monospaced: true)
                        previewListSection("签名证书", values: profile.certificates.map(certificateDescription))
                        previewListSection("Entitlements", values: profile.entitlementKeys, monospaced: true)
                    }

                    previewListSection("App Extension", values: info.appexes.map { "\($0.name.isEmpty ? $0.bundleIdentifier : $0.name)  \($0.bundleIdentifier)" })
                    previewListSection("Frameworks", values: info.frameworks)
                    previewListSection("动态库", values: info.dynamicLibraries)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(22)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 620, height: 560)
    }

    private var header: some View {
        HStack(spacing: 14) {
            appIcon

            VStack(alignment: .leading, spacing: 4) {
                Text(info.appName.isEmpty ? info.fileName : info.appName)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text(info.bundleIdentifier.isEmpty ? "未读取到 Bundle ID" : info.bundleIdentifier)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    badge(info.versionDescription, tint: .blue)
                    if let teamId = info.provisioningProfile?.teamIdentifier, !teamId.isEmpty {
                        badge("Team \(teamId)", tint: .green)
                    }
                    if let profileType = info.provisioningProfile?.profileType, !profileType.isEmpty {
                        badge(profileType, tint: .indigo)
                    }
                }
                .padding(.top, 3)
            }

            Spacer()
        }
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.28))
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let iconData = info.iconData, let image = NSImage(data: iconData) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 58, height: 58)
                .overlay {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
        }
    }

    private func previewSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(spacing: 8) {
                content()
            }
        }
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.25))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func previewListSection(_ title: String, values: [String], monospaced: Bool = false) -> some View {
        previewSection(title) {
            if values.isEmpty {
                Text("无")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(values, id: \.self) { value in
                    Text(value)
                        .font(monospaced ? .system(.subheadline, design: .monospaced) : .subheadline)
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func previewRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 94, alignment: .leading)
            Text(value.isEmpty ? "-" : value)
                .font(.subheadline)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func profileBadges(_ profile: IPAPreviewProvisioningProfile) -> some View {
        HStack(spacing: 8) {
            badge(profile.profileType, tint: .indigo)
            badge("Team \(profile.teamIdentifier.isEmpty ? "-" : profile.teamIdentifier)", tint: .green)
            badge(deviceSummary(profile), tint: .blue)
            badge(profile.expirationDate.map(expirationStatus) ?? "有效期未知", tint: expirationTint(profile.expirationDate))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 2)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text.isEmpty ? "-" : text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.vertical, 4)
            .padding(.horizontal, 9)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func deviceValues(_ profile: IPAPreviewProvisioningProfile) -> [String] {
        if profile.provisionsAllDevices {
            return ["全部设备"]
        }
        return profile.provisionedDevices
    }

    private func certificateDescription(_ certificate: IPAPreviewCertificate) -> String {
        var parts = [certificate.commonName]
        if !certificate.organization.isEmpty {
            parts.append(certificate.organization)
        }
        if !certificate.countryName.isEmpty {
            parts.append(certificate.countryName)
        }
        if !certificate.teamIdentifier.isEmpty {
            parts.append("Team ID: \(certificate.teamIdentifier)")
        }
        if let notBefore = certificate.notBefore {
            parts.append("生效: \(notBefore.formatString(format: "yyyy-MM-dd"))")
        }
        if let notAfter = certificate.notAfter {
            parts.append("过期: \(notAfter.formatString(format: "yyyy-MM-dd"))")
        }
        if !certificate.sha1Fingerprint.isEmpty {
            parts.append("SHA1: \(certificate.sha1Fingerprint)")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "  ")
    }

    private func deviceSummary(_ profile: IPAPreviewProvisioningProfile) -> String {
        if profile.provisionsAllDevices {
            return "全部设备"
        }
        return "\(profile.provisionedDeviceCount) 台设备"
    }

    private func expirationStatus(_ date: Date) -> String {
        date < Date() ? "已过期" : "有效至 \(date.formatString(format: "yyyy-MM-dd"))"
    }

    private func expirationTint(_ date: Date?) -> Color {
        guard let date else {
            return .gray
        }
        return date < Date() ? .red : .orange
    }
}
