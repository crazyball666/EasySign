import SwiftUI
import AppKit

/// 应用详情弹窗。数据全部来自 AppLister 那一次 Lookup(见 AppLister.lookupAttributes),
/// 打开时不再访问设备,所以是瞬开的。
struct AppDetailSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    let app: InstalledApp
    let icon: NSImage?

    var body: some View {
        let palette = GlassPalette(colorScheme: colorScheme)
        GlassCanvas {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: GlassMetric.spacingL) {
                        section("基本信息", "info.circle") { basicRows }
                        section("签名与身份", "checkmark.shield") { signingRows }
                        section("构建信息", "hammer") { buildRows }
                        if !app.detail.urlSchemes.isEmpty || !app.detail.backgroundModes.isEmpty {
                            section("能力", "bolt") { capabilityRows }
                        }
                        section("路径", "folder") { pathRows }
                        if !app.detail.entitlements.isEmpty {
                            section("Entitlements (\(app.detail.entitlements.count))", "key") {
                                ForEach(app.detail.entitlements) { kv in
                                    detailRow(kv.key, kv.value, mono: true)
                                }
                            }
                        }
                    }
                    .padding(GlassMetric.spacingL)
                }
                Divider().opacity(0.5)
                HStack {
                    Text(app.bundleID)
                        .font(.caption)
                        .foregroundStyle(palette.mutedText)
                        .textSelection(.enabled)
                    Spacer()
                    Button("完成") { dismiss() }
                        .buttonStyle(GlassButtonStyle(.primary))
                        .keyboardShortcut(.defaultAction)
                }
                .padding(GlassMetric.spacingM)
            }
        }
        .frame(width: 560, height: 620)
    }

    // MARK: - Header

    private var header: some View {
        let palette = GlassPalette(colorScheme: colorScheme)
        return HStack(spacing: GlassMetric.spacingM) {
            AppIconView(app: app, icon: icon, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                Text(app.bundleID)
                    .font(.caption)
                    .foregroundStyle(palette.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: GlassMetric.spacingXS) {
                    SigningBadge(app: app)
                    if app.detail.isAppClip { tag("App Clip") }
                    if app.detail.fileSharingEnabled { tag("文件共享") }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(GlassMetric.spacingL)
    }

    private func tag(_ text: String) -> some View {
        let palette = GlassPalette(colorScheme: colorScheme)
        return Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule(style: .continuous).fill(palette.primaryStart.opacity(0.15)))
            .foregroundStyle(palette.primaryStart)
    }

    // MARK: - Sections

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        _ icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: GlassMetric.spacingS) {
            GlassSectionTitle(title, icon: icon)
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .glassSurface(.inset, radius: GlassMetric.radiusMedium, padding: GlassMetric.spacingM)
        }
    }

    @ViewBuilder
    private var basicRows: some View {
        detailRow("版本", app.version.isEmpty ? "—" : app.version)
        detailRow("构建版本", app.buildVersion.isEmpty ? "—" : app.buildVersion)
        detailRow("类型", applicationTypeText)
        if !app.detail.executable.isEmpty { detailRow("可执行文件", app.detail.executable) }
        if !app.detail.developmentRegion.isEmpty { detailRow("开发区域", app.detail.developmentRegion) }
        if !app.detail.deviceFamilies.isEmpty { detailRow("设备类型", app.detail.deviceFamilyText) }
        detailRow("可升级", app.detail.isUpgradeable ? "是" : "否")
    }

    @ViewBuilder
    private var signingRows: some View {
        detailRow("签名类型", app.badgeLabel)
        if !app.detail.signerIdentity.isEmpty {
            detailRow("签名者", app.detail.signerIdentity, mono: true)
        }
        if !app.detail.teamID.isEmpty {
            detailRow("Team ID", app.detail.teamID, mono: true)
        }
        if !app.detail.applicationDSID.isEmpty {
            detailRow("购买账号 DSID", app.detail.applicationDSID, mono: true)
        }
    }

    @ViewBuilder
    private var buildRows: some View {
        if !app.detail.minimumOSVersion.isEmpty { detailRow("最低系统", "iOS \(app.detail.minimumOSVersion)") }
        if !app.detail.sdkName.isEmpty { detailRow("构建 SDK", app.detail.sdkName) }
        if !app.detail.platformVersion.isEmpty { detailRow("平台版本", app.detail.platformVersion) }
        if !app.detail.xcodeVersion.isEmpty { detailRow("Xcode", formattedXcode) }
        if !app.detail.supportedPlatforms.isEmpty {
            detailRow("支持平台", app.detail.supportedPlatforms.joined(separator: ", "))
        }
    }

    @ViewBuilder
    private var capabilityRows: some View {
        if !app.detail.urlSchemes.isEmpty {
            detailRow("URL Scheme", app.detail.urlSchemes.joined(separator: ", "), mono: true)
        }
        if !app.detail.backgroundModes.isEmpty {
            detailRow("后台模式", app.detail.backgroundModes.joined(separator: ", "))
        }
        detailRow("文件共享", app.detail.fileSharingEnabled ? "已开启" : "未开启")
    }

    @ViewBuilder
    private var pathRows: some View {
        detailRow("App 包", app.path, mono: true)
        if !app.detail.container.isEmpty {
            detailRow("数据容器", app.detail.container, mono: true)
        }
        ForEach(app.detail.groupContainers) { kv in
            detailRow(kv.key, kv.value, mono: true)
        }
    }

    // MARK: - Row

    private func detailRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        let palette = GlassPalette(colorScheme: colorScheme)
        return HStack(alignment: .top, spacing: GlassMetric.spacingM) {
            Text(label)
                .font(.caption)
                .foregroundStyle(palette.mutedText)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 11, design: .monospaced) : .caption)
                // 详情就是给人看细节的,长路径/长 entitlement 一律换行显示,不截断。
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var applicationTypeText: String {
        switch app.detail.applicationType {
        case "User": "用户 App"
        case "System": "系统 App"
        case "Hidden": "系统隐藏 App"
        default: app.detail.applicationType.isEmpty ? "—" : app.detail.applicationType
        }
    }

    /// DTXcode 是 "2600" 这种四位编码 → 26.0.0
    private var formattedXcode: String {
        let raw = app.detail.xcodeVersion
        guard raw.count == 4, let n = Int(raw) else { return raw }
        return "\(n / 100).\(n / 10 % 10).\(n % 10)"
    }
}

// MARK: - 共用小组件

/// 真实图标(拿得到就用),否则退回按 bundleID 哈希着色的字母占位图。
struct AppIconView: View {
    let app: InstalledApp
    let icon: NSImage?
    var size: CGFloat = 38

    var body: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                // SpringBoard 返回的 PNG 已经烘焙了圆角,这里只做轻微裁切兜底。
                .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
        } else {
            AppIconPlaceholder(app: app, size: size)
        }
    }
}

struct SigningBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    let app: InstalledApp

    var body: some View {
        let color = Self.color(for: app, colorScheme: colorScheme)
        Text(app.badgeLabel)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule(style: .continuous).fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    static func color(for app: InstalledApp, colorScheme: ColorScheme) -> Color {
        let palette = GlassPalette(colorScheme: colorScheme)
        if app.isSystemApp { return palette.mutedText }
        switch app.signingInfo {
        case .appStore: return palette.primaryStart
        case .testFlight: return palette.primaryEnd
        case .development: return palette.success
        case .distribution: return palette.primaryEnd
        case .enterprise: return palette.warning
        case .system: return palette.mutedText
        case .unknown: return palette.mutedText
        }
    }
}
