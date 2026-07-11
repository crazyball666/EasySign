//
//  PreviewViews.swift
//  EasySignQuickLook
//
//  QuickLook 预览的 SwiftUI 界面。组件体系参考 ProvisionQL
//  (表格化列表、等宽代码块、克制的语义色),保留 EasySign 原有的
//  图标+徽章头部、中文字段、剩余天数、证书状态横幅。
//

import SwiftUI
import PreviewKit

// MARK: - 根视图

struct AppPreviewRootView: View {
    let info: IPAPreviewInfo

    var body: some View {
        PreviewDocument {
            AppHeaderView(info: info)

            PreviewCard("基础信息") {
                InfoRow("文件", info.fileName)
                InfoRow("大小", ByteCountFormatter.string(fromByteCount: info.fileSize, countStyle: .file))
                InfoRow("App 目录", info.appDirectoryName)
                InfoRow("Bundle ID", info.bundleIdentifier)
                InfoRow("版本", info.versionDescription)
                InfoRow("最低系统", info.minimumOSVersion ?? "-")
                InfoRow("可执行文件", info.executableName ?? "-")
                Divider()
                InfoRow("签名状态", info.signingDescription)
            }

            if !info.appEntitlementLines.isEmpty {
                PreviewCard("App Entitlements") {
                    // 可执行文件里实际签入的 entitlements,区别于描述文件声明,
                    // 是排查「重签后推送/群组权限丢了」的关键信息
                    Text("从可执行文件签名中读取,实际生效的权限")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    CodeBlock(lines: info.appEntitlementLines)
                }
            }

            if let profile = info.provisioningProfile {
                PreviewCard("描述文件") {
                    ProfileDetailsView(profile: profile)
                }
            } else {
                PreviewCard("描述文件") {
                    InfoRow("状态", "未内嵌描述文件")
                }
            }

            componentsCard

            PreviewFooter()
        }
    }

    @ViewBuilder
    private var componentsCard: some View {
        let appexLines = info.appexes.map { appex in
            "\(appex.name.isEmpty ? appex.bundleIdentifier : appex.name)  \(appex.bundleIdentifier)"
        }
        if !appexLines.isEmpty || !info.frameworks.isEmpty || !info.dynamicLibraries.isEmpty {
            PreviewCard("组件") {
                if !appexLines.isEmpty {
                    ListSubsection(title: "App Extension(\(appexLines.count))", lines: appexLines, mono: false)
                }
                if !info.frameworks.isEmpty {
                    ListSubsection(title: "Frameworks(\(info.frameworks.count))", lines: info.frameworks, mono: true)
                }
                if !info.dynamicLibraries.isEmpty {
                    ListSubsection(title: "动态库(\(info.dynamicLibraries.count))", lines: info.dynamicLibraries, mono: true)
                }
            }
        }
    }
}

struct ProfilePreviewRootView: View {
    let file: IPAPreviewProfileFile

    var body: some View {
        PreviewDocument {
            ProfileHeaderView(file: file)

            PreviewCard("文件") {
                InfoRow("文件名", file.fileName)
                InfoRow("大小", ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file))
            }

            PreviewCard("描述文件") {
                ProfileDetailsView(profile: file.profile)
            }

            PreviewFooter()
        }
    }
}

// MARK: - 头部

private struct AppHeaderView: View {
    let info: IPAPreviewInfo

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            iconView

            VStack(alignment: .leading, spacing: 4) {
                Text(info.appName.isEmpty ? info.fileName : info.appName)
                    .font(.system(size: 21, weight: .bold))
                    .textSelection(.enabled)
                Text(info.bundleIdentifier.isEmpty ? "未读取到 Bundle ID" : info.bundleIdentifier)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                badges
                    .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .previewCardBackground()
    }

    private var badges: some View {
        HStack(spacing: 6) {
            StatusBadge(text: info.versionDescription, tint: PreviewPalette.identity)
            if let teamId = info.provisioningProfile?.teamIdentifier, !teamId.isEmpty {
                StatusBadge(text: "Team \(teamId)", tint: PreviewPalette.neutral)
            }
            if let profileType = info.provisioningProfile?.profileType, !profileType.isEmpty {
                StatusBadge(text: profileType, tint: PreviewPalette.category)
            }
            if let profile = info.provisioningProfile {
                StatusBadge(
                    text: validityText(profile.validityStatus, days: profile.daysUntilExpiry),
                    tint: profile.validityStatus.uiColor
                )
            }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = info.iconData.flatMap(NSImage.init(data:)) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.gray.opacity(0.12))
                .frame(width: 72, height: 72)
                .overlay(
                    Image(systemName: "app.dashed")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.tertiary)
                )
        }
    }
}

private struct ProfileHeaderView: View {
    let file: IPAPreviewProfileFile

    var body: some View {
        let profile = file.profile
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "doc.badge.gearshape")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name.isEmpty ? file.fileName : profile.name)
                    .font(.system(size: 21, weight: .bold))
                    .textSelection(.enabled)
                Text(teamLine(profile))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    StatusBadge(text: profile.profileType, tint: PreviewPalette.category)
                    StatusBadge(
                        text: validityText(profile.validityStatus, days: profile.daysUntilExpiry),
                        tint: profile.validityStatus.uiColor
                    )
                    StatusBadge(
                        text: profile.provisionsAllDevices ? "全部设备" : "\(profile.provisionedDeviceCount) 台设备",
                        tint: PreviewPalette.neutral
                    )
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .previewCardBackground()
    }

    private func teamLine(_ profile: IPAPreviewProvisioningProfile) -> String {
        if profile.teamName.isEmpty {
            return profile.teamIdentifier.isEmpty ? "未读取到 Team 信息" : profile.teamIdentifier
        }
        return profile.teamIdentifier.isEmpty
            ? profile.teamName
            : "\(profile.teamName)  (\(profile.teamIdentifier))"
    }
}

// MARK: - 描述文件详情(ipa 内嵌与独立文件共用)

struct ProfileDetailsView: View {
    let profile: IPAPreviewProvisioningProfile

    var body: some View {
        InfoRow(
            "有效性",
            validityText(profile.validityStatus, days: profile.daysUntilExpiry),
            color: profile.validityStatus.uiColor
        )
        InfoRow("名称", profile.name)
        InfoRow("类型", profile.profileType)
        InfoRow("Team", teamText)
        InfoRow("App ID", profile.applicationIdentifier)
        InfoRow("UUID", profile.uuid, mono: true)
        InfoRow("创建时间", formatDate(profile.creationDate))
        InfoRow(
            "过期时间",
            formatDate(profile.expirationDate),
            color: profile.validityStatus == .valid ? nil : profile.validityStatus.uiColor
        )
        InfoRow("APS 环境", profile.apsEnvironment ?? "-")
        InfoRow("调试权限", profile.getTaskAllow.map { $0 ? "是" : "否" } ?? "-")

        if !profile.certificates.isEmpty {
            Divider()
            CertificatesSection(certificates: profile.certificates)
        }

        if !profile.entitlementLines.isEmpty {
            Divider()
            CollapsibleSection(
                title: "Entitlements(\(profile.entitlementKeys.count))",
                isInitiallyExpanded: profile.entitlementLines.count <= 15
            ) {
                CodeBlock(lines: profile.entitlementLines)
            }
        }

        Divider()
        DevicesSection(profile: profile)
    }

    private var teamText: String {
        if profile.teamName.isEmpty {
            return profile.teamIdentifier
        }
        return profile.teamIdentifier.isEmpty
            ? profile.teamName
            : "\(profile.teamName)  (\(profile.teamIdentifier))"
    }
}

// MARK: - 证书

private struct CertificatesSection: View {
    let certificates: [IPAPreviewCertificate]

    var body: some View {
        CollapsibleSection(title: "签名证书(\(certificates.count))", isInitiallyExpanded: true) {
            banner
            PreviewTable(certificates) { certificate in
                CertificateRow(certificate: certificate)
            }
        }
    }

    @ViewBuilder
    private var banner: some View {
        let statuses = certificates.map(\.validityStatus)
        let allValid = statuses.allSatisfy { $0 == .valid }
        let anyExpired = statuses.contains(.expired)
        let anyExpiring = statuses.contains(.expiringSoon)
        // 分三档:全有效(绿)/ 有已过期(红)/ 其余(橙,含即将过期与未生效),
        // 措辞按实际情况区分,不再把「未生效」误报成「即将过期」
        let tint: Color = allValid
            ? PreviewPalette.valid
            : (anyExpired ? PreviewPalette.expired : PreviewPalette.warning)
        let text: String = {
            if allValid { return "所有 \(certificates.count) 张证书均在有效期内" }
            if anyExpired { return "存在已过期的证书" }
            if anyExpiring { return "部分证书即将过期" }
            return "存在尚未生效的证书"
        }()

        Label(text, systemImage: allValid ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.1))
            )
    }
}

private struct CertificateRow: View {
    let certificate: IPAPreviewCertificate

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(certificate.commonName.isEmpty ? "(无 CN)" : certificate.commonName)
                    .font(.system(size: 12.5, weight: .medium))
                    .textSelection(.enabled)

                if !metaText.isEmpty {
                    Text(metaText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if !certificate.sha1Fingerprint.isEmpty {
                    Text("SHA-1  \(certificate.sha1Fingerprint)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 3) {
                Text(formatDate(certificate.notAfter, dateOnly: true))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(certificate.validityStatus == .valid ? Color.primary : certificate.validityStatus.uiColor)
                Text(validityText(certificate.validityStatus, days: certificate.daysUntilExpiry))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(certificate.validityStatus.uiColor)
            }
        }
    }

    private var metaText: String {
        var parts: [String] = []
        if !certificate.organization.isEmpty {
            parts.append(certificate.organization)
        }
        if !certificate.teamIdentifier.isEmpty {
            parts.append("Team \(certificate.teamIdentifier)")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 设备

private struct DevicesSection: View {
    let profile: IPAPreviewProvisioningProfile

    var body: some View {
        if profile.provisionsAllDevices {
            InfoRow("设备", "全部设备(企业分发)")
        } else if profile.provisionedDevices.isEmpty {
            InfoRow("设备", "无(App Store 分发)")
        } else {
            // 大型 Ad Hoc 描述文件动辄上百台设备,默认收起,点击展开
            CollapsibleSection(
                title: "设备列表(\(profile.provisionedDeviceCount) 台)",
                isInitiallyExpanded: profile.provisionedDevices.count <= 20
            ) {
                PreviewTable(profile.provisionedDevices) { udid in
                    Text(udid)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - 通用组件

/// 整页容器:滚动 + 统一留白
struct PreviewDocument<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 圆角卡片,带小节标题
struct PreviewCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .previewCardBackground()
    }
}

private struct PreviewCardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
            )
    }
}

extension View {
    func previewCardBackground() -> some View {
        modifier(PreviewCardBackground())
    }
}

/// 键值行:固定宽度的次要色键 + 可选中的值
struct InfoRow: View {
    let label: String
    let value: String
    var color: Color?
    var mono: Bool

    init(_ label: String, _ value: String, color: Color? = nil, mono: Bool = false) {
        self.label = label
        self.value = value
        self.color = color
        self.mono = mono
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .leading)

            Text(value.isEmpty ? "-" : value)
                .font(.system(size: 12.5, weight: color == nil ? .regular : .semibold, design: mono ? .monospaced : .default))
                .foregroundStyle(color ?? Color.primary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 徽章:着色胶囊
struct StatusBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.13))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(tint.opacity(0.22), lineWidth: 1)
            )
    }
}

/// 可折叠小节:点击标题行展开/收起
struct CollapsibleSection<Content: View>: View {
    let title: String
    @State private var isExpanded: Bool
    @ViewBuilder let content: Content

    init(title: String, isInitiallyExpanded: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        _isExpanded = State(initialValue: isInitiallyExpanded)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
            }
        }
    }
}

/// 表格:圆角描边容器,行间分隔线(参考 ProvisionQL 的 TableSection)
struct PreviewTable<Element, RowContent: View>: View {
    let data: [Element]
    @ViewBuilder let rowContent: (Element) -> RowContent

    init(_ data: [Element], @ViewBuilder rowContent: @escaping (Element) -> RowContent) {
        self.data = data
        self.rowContent = rowContent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(data.indices, id: \.self) { index in
                rowContent(data[index])
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                if index < data.count - 1 {
                    Divider()
                }
            }
        }
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 1)
        )
    }
}

/// 等宽代码块(entitlements 等)
struct CodeBlock: View {
    let lines: [String]

    var body: some View {
        Text(lines.joined(separator: "\n"))
            .font(.system(size: 11.5, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
    }
}

/// 组件卡里的分组列表(App Extension / Frameworks / 动态库)
private struct ListSubsection: View {
    let title: String
    let lines: [String]
    let mono: Bool

    var body: some View {
        CollapsibleSection(title: title, isInitiallyExpanded: lines.count <= 12) {
            PreviewTable(lines) { line in
                Text(line)
                    .font(.system(size: 12, design: mono ? .monospaced : .default))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// 页脚:标注生成来源和版本
private struct PreviewFooter: View {
    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        HStack {
            Spacer()
            Text("EasySign\(version.isEmpty ? "" : " v\(version)")")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.top, 2)
    }
}

// MARK: - 配色

/// 预览统一调色板。原则:颜色只表达状态语义,身份信息(版本、Team、计数)
/// 用中性色,避免满屏彩虹。
enum PreviewPalette {
    /// 「有效」绿。SwiftUI 原生 .green 在浅色模式下太亮,小字号可读性差
    /// (ProvisionQL 同样为此自定义了深绿),深浅模式分别取色。
    static let valid = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .systemGreen
            : NSColor(red: 0.0, green: 0.55, blue: 0.15, alpha: 1.0)
    })
    static let warning = Color(nsColor: .systemOrange)
    static let expired = Color(nsColor: .systemRed)
    /// 主标识(版本号)
    static let identity = Color(nsColor: .systemBlue)
    /// 分类(描述文件类型)
    static let category = Color(nsColor: .systemIndigo)
    /// 中性徽章(Team、设备数等事实信息)
    static let neutral = Color(nsColor: .secondaryLabelColor)
}

extension ValidityStatus {
    var uiColor: Color {
        switch self {
        // 「未生效」黄色文字在白底上不可读,和「即将过期」一样归为警示橙,
        // 具体语义由文字本身("未生效"/"即将过期")区分
        case .notYetValid:  return PreviewPalette.warning
        case .valid:        return PreviewPalette.valid
        case .expiringSoon: return PreviewPalette.warning
        case .expired:      return PreviewPalette.expired
        }
    }
}

private func validityText(_ status: ValidityStatus, days: Int?) -> String {
    var text = status.label
    if let days {
        if days > 0 {
            text += " · 还剩 \(days) 天"
        } else if days == 0 {
            text += " · 今天到期"
        } else {
            text += " · 已过期 \(-days) 天"
        }
    }
    return text
}

// DateFormatter 构造很贵,证书/日期行会在 ForEach 里逐行调用,缓存复用避免卡顿
private let dateOnlyFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private let dateTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

private func formatDate(_ date: Date?, dateOnly: Bool = false) -> String {
    guard let date else {
        return "-"
    }
    return (dateOnly ? dateOnlyFormatter : dateTimeFormatter).string(from: date)
}
