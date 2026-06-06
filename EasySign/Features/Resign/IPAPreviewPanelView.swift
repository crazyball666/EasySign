//
//  IPAPreviewPanelView.swift
//  EasySign
//

import SwiftUI

struct IPAPreviewPanelView: View {
    let info: IPAPreviewInfo
    @State private var selectedTab: PreviewTab = .info

    enum PreviewTab: String, CaseIterable, Identifiable {
        case info = "应用信息"
        case profile = "描述文件"
        case certificates = "证书"
        case contents = "内容"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            heroHeader
            tabBar
            Divider()
            ScrollView {
                Group {
                    switch selectedTab {
                    case .info: infoTab
                    case .profile: profileTab
                    case .certificates: certificatesTab
                    case .contents: contentsTab
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 720, minHeight: 580)
    }

    // MARK: - Hero header

    private var heroHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            appIcon

            VStack(alignment: .leading, spacing: 6) {
                Text(info.appName.isEmpty ? info.fileName : info.appName)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text(info.bundleIdentifier.isEmpty ? "未读取到 Bundle ID" : info.bundleIdentifier)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                heroBadges
            }

            Spacer()

            fileMeta
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.08),
                    Color(nsColor: .windowBackgroundColor)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    @ViewBuilder
    private var appIcon: some View {
        if let iconData = info.iconData, let image = NSImage(data: iconData) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 72, height: 72)
                .overlay {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
        }
    }

    private var heroBadges: some View {
        HStack(spacing: 6) {
            badge(info.versionDescription, tint: .blue, icon: "tag")
            if let teamId = info.provisioningProfile?.teamIdentifier, !teamId.isEmpty {
                badge("Team \(teamId)", tint: .green, icon: "person.3")
            }
            if let profileType = info.provisioningProfile?.profileType, !profileType.isEmpty {
                badge(profileType, tint: .indigo, icon: "doc.badge.gearshape")
            }
        }
    }

    private var fileMeta: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(info.fileName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(formatFileSize(info.fileSize))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(PreviewTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: iconForTab(tab))
                            .font(.caption)
                        Text(tab.rawValue)
                            .font(.subheadline)
                        if let count = tabBadgeCount(tab) {
                            Text("\(count)")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.2), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Rectangle()
                            .fill(selectedTab == tab ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(selectedTab == tab ? Color.accentColor : Color.clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .background(.bar)
    }

    private func iconForTab(_ tab: PreviewTab) -> String {
        switch tab {
        case .info: return "info.circle"
        case .profile: return "doc.badge.gearshape"
        case .certificates: return "key.horizontal"
        case .contents: return "shippingbox"
        }
    }

    private func tabBadgeCount(_ tab: PreviewTab) -> Int? {
        switch tab {
        case .certificates:
            return info.provisioningProfile?.certificates.count
        case .contents:
            let n = info.appexes.count + info.frameworks.count + info.dynamicLibraries.count
            return n > 0 ? n : nil
        default:
            return nil
        }
    }

    // MARK: - Tab: Info

    private var infoTab: some View {
        VStack(spacing: 16) {
            cardSection(title: "基础信息", icon: "info.circle") {
                KeyValueGrid(rows: [
                    ("文件", info.fileName),
                    ("App 目录", info.appDirectoryName),
                    ("Bundle ID", info.bundleIdentifier),
                    ("版本", info.versionDescription),
                    ("最低系统", info.minimumOSVersion ?? "-"),
                    ("可执行文件", info.executableName ?? "-"),
                ])
            }

            cardSection(title: "签名信息", icon: "signature") {
                KeyValueGrid(rows: [
                    ("签名状态", info.signingDescription),
                    ("CodeResources", info.codeSignature.codeResourcesPath ?? "未发现"),
                ])
            }
        }
    }

    // MARK: - Tab: Profile

    private var profileTab: some View {
        VStack(spacing: 16) {
            if let profile = info.provisioningProfile {
                profileHeroCard(profile)
                cardSection(title: "描述文件详情", icon: "doc.text") {
                    KeyValueGrid(rows: [
                        ("名称", profile.name),
                        ("UUID", profile.uuid),
                        ("Team Name", profile.teamName),
                        ("Team ID", profile.teamIdentifier),
                        ("App ID", profile.applicationIdentifier),
                        ("创建时间", profile.creationDate?.formatString(format: "yyyy-MM-dd HH:mm:ss") ?? "-"),
                        ("过期时间", profile.expirationDate?.formatString(format: "yyyy-MM-dd HH:mm:ss") ?? "-"),
                        ("设备数", profile.provisionsAllDevices ? "全部设备" : "\(profile.provisionedDeviceCount)"),
                        ("Entitlements", "\(profile.entitlementKeys.count)"),
                        ("APS", profile.apsEnvironment ?? "-"),
                        ("调试权限", profile.getTaskAllow.map { $0 ? "YES" : "NO" } ?? "-"),
                    ])
                }
                if !profile.provisionedDevices.isEmpty && !profile.provisionsAllDevices {
                    cardSection(title: "已注册设备 (\(profile.provisionedDevices.count))", icon: "iphone") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(profile.provisionedDevices, id: \.self) { udid in
                                Text(udid)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                }
            } else {
                emptyState(icon: "doc.badge.gearshape", message: "该 IPA 未内嵌描述文件")
            }
        }
    }

    private func profileHeroCard(_ profile: IPAPreviewProvisioningProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "doc.badge.gearshape.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.headline)
                    Text(profile.profileType)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ValidityBadge(status: profile.validityStatus, daysLeft: profile.daysUntilExpiry)
            }
            HStack(spacing: 20) {
                if let exp = profile.expirationDate {
                    dateStat(label: "生效", date: profile.creationDate, color: .secondary)
                    dateStat(label: "过期", date: exp, color: validityColor(profile.validityStatus))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(tint: validityColor(profile.validityStatus).opacity(0.06)))
        .overlay(cardBorder(tint: validityColor(profile.validityStatus).opacity(0.4)))
    }

    // MARK: - Tab: Certificates

    private var certificatesTab: some View {
        VStack(spacing: 16) {
            if let certs = info.provisioningProfile?.certificates, !certs.isEmpty {
                overallStatusBanner
                ForEach(Array(certs.enumerated()), id: \.element.id) { (i, cert) in
                    CertificateCard(cert: cert, index: i)
                }
            } else {
                emptyState(icon: "key.slash", message: "该描述文件未内嵌证书")
            }
        }
    }

    private var overallStatusBanner: some View {
        let certs = info.provisioningProfile?.certificates ?? []
        let statuses = certs.map { $0.validityStatus }
        let allValid = !statuses.isEmpty && statuses.allSatisfy { $0 == .valid }
        let anyExpired = statuses.contains(.expired)
        let icon = allValid ? "checkmark.seal.fill" : (anyExpired ? "xmark.seal.fill" : "exclamationmark.triangle.fill")
        let text = allValid
            ? "所有 \(certs.count) 张证书均在有效期内"
            : (anyExpired ? "存在已过期的证书" : "部分证书即将过期")
        let tint: Color = allValid ? .green : (anyExpired ? .red : .orange)
        return HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(tint)
            Text(text)
                .font(.headline)
            Spacer()
        }
        .padding(14)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.4), lineWidth: 1))
    }

    // MARK: - Tab: Contents

    private var contentsTab: some View {
        VStack(spacing: 16) {
            contentsGroup(title: "App Extensions", icon: "puzzlepiece.extension",
                         count: info.appexes.count,
                         items: info.appexes.map { "\($0.name.isEmpty ? $0.bundleIdentifier : $0.name) · \($0.bundleIdentifier)" })
            contentsGroup(title: "Frameworks", icon: "cube.box",
                         count: info.frameworks.count,
                         items: info.frameworks)
            contentsGroup(title: "动态库", icon: "bolt.horizontal",
                         count: info.dynamicLibraries.count,
                         items: info.dynamicLibraries)
        }
    }

    private func contentsGroup(title: String, icon: String, count: Int, items: [String]) -> some View {
        cardSection(title: "\(title)（\(count)）", icon: icon) {
            if items.isEmpty {
                Text("无")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items, id: \.self) { value in
                        Text(value)
                            .font(.system(.subheadline, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func cardSection<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground())
        .overlay(cardBorder())
    }

    private func cardBackground(tint: Color = Color.clear) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay(tint)
    }

    private func cardBorder(tint: Color = Color.clear) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color(nsColor: .separatorColor).opacity(0.5))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(tint))
    }

    private func dateStat(label: String, date: Date?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let date {
                Text(date.formatString(format: "yyyy-MM-dd HH:mm"))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(color)
            } else {
                Text("-")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func emptyState(icon: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(40)
    }

    private func badge(_ text: String, tint: Color, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .lineLimit(1)
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func validityColor(_ status: ValidityStatus) -> Color {
        switch status {
        case .notYetValid, .expiringSoon: return .orange
        case .valid: return .green
        case .expired: return .red
        }
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

// MARK: - Validity badge

private struct ValidityBadge: View {
    let status: ValidityStatus
    let daysLeft: Int?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.subheadline)
            VStack(alignment: .leading, spacing: 0) {
                Text(status.label)
                    .font(.subheadline.weight(.semibold))
                if let days = daysLeft {
                    Text(daysText(days))
                        .font(.caption2)
                }
            }
        }
        .foregroundStyle(tint)
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.5), lineWidth: 1))
    }

    private var iconName: String {
        switch status {
        case .valid: return "checkmark.seal.fill"
        case .expiringSoon: return "clock.badge.exclamationmark"
        case .expired: return "xmark.seal.fill"
        case .notYetValid: return "hourglass"
        }
    }

    private var tint: Color {
        switch status {
        case .valid: return .green
        case .expiringSoon: return .orange
        case .expired: return .red
        case .notYetValid: return .yellow
        }
    }

    private func daysText(_ days: Int) -> String {
        if days > 0 { return "还剩 \(days) 天" }
        if days == 0 { return "今天到期" }
        return "已过期 \(-days) 天"
    }
}

// MARK: - Certificate card

private struct CertificateCard: View {
    let cert: IPAPreviewCertificate
    let index: Int

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(validityColor.opacity(0.14))
                    .frame(width: 48, height: 48)
                Image(systemName: validityIcon)
                    .font(.system(size: 22))
                    .foregroundStyle(validityColor)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(cert.commonName.isEmpty ? "(无 CN)" : cert.commonName)
                        .font(.headline)
                        .lineLimit(1)
                    if !cert.organization.isEmpty {
                        Text(cert.organization)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 14) {
                    if let notBefore = cert.notBefore {
                        statChip(icon: "play.circle", label: "生效", value: notBefore, color: .secondary)
                    }
                    if let notAfter = cert.notAfter {
                        statChip(icon: "stop.circle", label: "过期", value: notAfter, color: validityColor)
                    }
                }
                if !cert.sha1Fingerprint.isEmpty {
                    HStack(spacing: 4) {
                        Text("SHA-1:")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(cert.sha1Fingerprint)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                ValidityBadge(status: cert.validityStatus, daysLeft: cert.daysUntilExpiry)
                if !cert.teamIdentifier.isEmpty {
                    Text("Team \(cert.teamIdentifier)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(cardBackground)
        .overlay(cardBorder)
    }

    private func statChip(icon: String, label: String, value: Date, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.caption2)
            Text("\(label) \(value.formatString(format: "yyyy-MM-dd"))")
                .font(.system(.caption, design: .monospaced))
        }
        .foregroundStyle(color)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor))
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(validityColor.opacity(0.4), lineWidth: 1)
    }

    private var validityColor: Color {
        switch cert.validityStatus {
        case .valid: return .green
        case .expiringSoon: return .orange
        case .expired: return .red
        case .notYetValid: return .yellow
        }
    }

    private var validityIcon: String {
        switch cert.validityStatus {
        case .valid: return "checkmark.seal.fill"
        case .expiringSoon: return "clock.badge.exclamationmark"
        case .expired: return "xmark.seal.fill"
        case .notYetValid: return "hourglass"
        }
    }
}

// MARK: - KeyValueGrid (label-value 两列网格)

private struct KeyValueGrid: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { (i, row) in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.0)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                    Text(row.1.isEmpty ? "-" : row.1)
                        .font(.subheadline)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 5)
                if i < rows.count - 1 {
                    Divider().opacity(0.3)
                }
            }
        }
    }
}
