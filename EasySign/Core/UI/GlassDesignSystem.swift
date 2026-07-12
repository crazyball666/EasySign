import SwiftUI

enum GlassThemePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var resolvedColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum GlassStatus: Equatable {
    case idle
    case active
    case success
    case warning
    case danger

    var title: String {
        switch self {
        case .idle: "待命"
        case .active: "进行中"
        case .success: "已完成"
        case .warning: "需注意"
        case .danger: "失败"
        }
    }

    var accessibilityLabel: String { title }

    var symbol: String {
        switch self {
        case .idle: "circle.dotted"
        case .active: "bolt.horizontal.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        }
    }

    var isAnimated: Bool { self == .active }
}

enum GlassSurfaceTone {
    case standard
    case emphasized
    case inset
}

/// 深色:低透明度白叠加,让画布透出来制造层次。
/// 浅色:叠加必须足够实 —— 卡片颜色若主要来自透出的画布渐变,
/// 同一页面不同位置的卡片会各偏一色(画布是对角渐变),观感失调;
/// 但仍留在不透明白之下,保住毛玻璃质感。
enum GlassMaterialRecipe {
    static func overlayOpacity(for tone: GlassSurfaceTone, colorScheme: ColorScheme) -> Double {
        switch (tone, colorScheme) {
        case (.standard, .dark): 0.08
        case (.standard, .light): 0.58
        case (.emphasized, .dark): 0.06
        case (.emphasized, .light): 0.55
        case (.inset, .dark): 0.13
        case (.inset, .light): 0.08
        default: 0.16
        }
    }

    static func borderOpacity(for tone: GlassSurfaceTone, colorScheme: ColorScheme) -> Double {
        switch (tone, colorScheme) {
        case (.standard, .dark): 0.16
        case (.standard, .light): 0.34
        case (.emphasized, .dark): 0.10
        case (.emphasized, .light): 0.22
        case (.inset, .dark): 0.09
        case (.inset, .light): 0.12
        default: 0.16
        }
    }

    static func highlightOpacity(for tone: GlassSurfaceTone, colorScheme: ColorScheme) -> Double {
        switch (tone, colorScheme) {
        case (.standard, .dark): 0.14
        case (.standard, .light): 0.32
        case (.emphasized, .dark): 0.09
        case (.emphasized, .light): 0.20
        case (.inset, .dark): 0.06
        case (.inset, .light): 0.12
        default: 0.12
        }
    }

    /// 浅色统一用 ultraThin:thinMaterial 自带的灰底和 ultraThin 卡片
    /// 色相不一致,并排摆放会一块发灰一块偏蓝。深色维持原映射。
    static func material(for tone: GlassSurfaceTone, colorScheme: ColorScheme) -> Material {
        if colorScheme != .dark { return .ultraThinMaterial }
        return switch tone {
        case .standard, .inset: .ultraThinMaterial
        case .emphasized: .thinMaterial
        }
    }

    /// 浅色画布近白,白基描边在其上不可见 —— 浅色下描边一律转黑基;
    /// 深色维持白基提亮的原配方。
    static func borderColor(for tone: GlassSurfaceTone, colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(borderOpacity(for: tone, colorScheme: .dark))
            : Color.black.opacity(lightBorderOpacity(for: tone))
    }

    static func lightBorderOpacity(for tone: GlassSurfaceTone) -> Double {
        switch tone {
        case .standard: 0.10
        case .emphasized: 0.07
        case .inset: 0.11
        }
    }

    /// 输入控件/次级按钮的底填充:深色用白 13% 提亮;浅色下对齐系统
    /// .roundedBorder 输入框的实白,玻璃控件与系统控件混排时才是一个白。
    static func controlFillOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.13 : 0.85
    }
}

/// The navigation rail uses a white-glass hierarchy rather than the system's
/// neutral gray selection treatment.
enum GlassSidebarRecipe {
    static func railWhiteOverlayOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.08 : 0.38
    }

    static func selectedFillOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.18 : 0.92
    }

    static func selectedBorderOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.32 : 0.86
    }

    static func dividerOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.14 : 0.42
    }
}

enum GlassButtonEmphasis {
    case primary
    case secondary
    case destructive
}

enum GlassMetric {
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 12
    static let spacingL: CGFloat = 16
    static let spacingXL: CGFloat = 20

    static let radiusSmall: CGFloat = 10
    static let radiusMedium: CGFloat = 14
    static let radiusLarge: CGFloat = 20
}

struct GlassPalette {
    let colorScheme: ColorScheme

    var canvas: Color {
        colorScheme == .dark
            ? Color(red: 0.035, green: 0.055, blue: 0.10)
            : Color(red: 0.92, green: 0.95, blue: 0.99)
    }

    var canvasGlow: Color {
        colorScheme == .dark
            ? Color(red: 0.11, green: 0.20, blue: 0.34)
            : Color(red: 0.76, green: 0.86, blue: 0.98)
    }

    var railOverlay: Color {
        Color.white.opacity(GlassMaterialRecipe.overlayOpacity(for: .emphasized, colorScheme: colorScheme))
    }

    var surfaceOverlay: Color {
        Color.white.opacity(GlassMaterialRecipe.overlayOpacity(for: .standard, colorScheme: colorScheme))
    }

    var insetFill: Color {
        Color.white.opacity(GlassMaterialRecipe.controlFillOpacity(for: colorScheme))
    }

    var border: Color {
        GlassMaterialRecipe.borderColor(for: .standard, colorScheme: colorScheme)
    }

    var mutedBorder: Color {
        GlassMaterialRecipe.borderColor(for: .inset, colorScheme: colorScheme)
    }

    var railDivider: Color {
        Color.white.opacity(GlassSidebarRecipe.dividerOpacity(for: colorScheme))
    }

    var primaryStart: Color { Color(red: 0.30, green: 0.91, blue: 0.76) }
    var primaryEnd: Color { Color(red: 0.55, green: 0.43, blue: 0.96) }
    var onAccentText: Color { .white }
    var success: Color { colorScheme == .dark ? Color(red: 0.34, green: 0.94, blue: 0.69) : Color(red: 0.05, green: 0.48, blue: 0.33) }
    var warning: Color { Color(red: 0.96, green: 0.61, blue: 0.16) }
    var danger: Color { Color(red: 0.94, green: 0.34, blue: 0.36) }
    var mutedText: Color { colorScheme == .dark ? Color.white.opacity(0.62) : Color.black.opacity(0.52) }

    var primaryGradient: LinearGradient {
        LinearGradient(colors: [primaryStart, primaryEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    func color(for status: GlassStatus) -> Color {
        switch status {
        case .idle: mutedText
        case .active: primaryStart
        case .success: success
        case .warning: warning
        case .danger: danger
        }
    }
}

struct GlassCanvas<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let palette = GlassPalette(colorScheme: colorScheme)
        ZStack {
            LinearGradient(
                colors: [palette.canvas, palette.canvasGlow.opacity(colorScheme == .dark ? 0.42 : 0.34), palette.canvas],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            content
        }
    }
}

private struct GlassSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let tone: GlassSurfaceTone
    let radius: CGFloat
    let padding: CGFloat?

    func body(content: Content) -> some View {
        let palette = GlassPalette(colorScheme: colorScheme)
        let fill: Color = switch tone {
        case .standard: palette.surfaceOverlay
        case .emphasized: palette.railOverlay
        case .inset: palette.insetFill
        }
        let border = GlassMaterialRecipe.borderColor(for: tone, colorScheme: colorScheme)
        let highlight = Color.white.opacity(GlassMaterialRecipe.highlightOpacity(for: tone, colorScheme: colorScheme))

        content
            .padding(padding ?? 0)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(GlassMaterialRecipe.material(for: tone, colorScheme: colorScheme))
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(fill)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(border, lineWidth: 1)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [highlight, .clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                            .padding(0.5)
                    }
                    .shadow(
                        color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.07),
                        radius: tone == .inset ? 4 : 12,
                        y: tone == .inset ? 2 : 6
                    )
            }
    }
}

private struct GlassSidebarRailModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let palette = GlassPalette(colorScheme: colorScheme)

        content
            .background {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        LinearGradient(
                            colors: [
                                Color.white.opacity(GlassSidebarRecipe.railWhiteOverlayOpacity(for: colorScheme)),
                                palette.railOverlay
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .overlay(alignment: .trailing) {
                        LinearGradient(
                            colors: [.clear, palette.railDivider, .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: 1)
                    }
            }
    }
}

extension View {
    func glassSurface(
        _ tone: GlassSurfaceTone = .standard,
        radius: CGFloat = GlassMetric.radiusMedium,
        padding: CGFloat? = nil
    ) -> some View {
        modifier(GlassSurfaceModifier(tone: tone, radius: radius, padding: padding))
    }

    func glassSidebarRail() -> some View {
        modifier(GlassSidebarRailModifier())
    }
}

struct GlassButtonStyle: ButtonStyle {
    let emphasis: GlassButtonEmphasis

    init(_ emphasis: GlassButtonEmphasis = .secondary) {
        self.emphasis = emphasis
    }

    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, emphasis: emphasis)
    }

    private struct GlassButtonBody: View {
        @Environment(\.colorScheme) private var colorScheme
        let configuration: ButtonStyle.Configuration
        let emphasis: GlassButtonEmphasis

        var body: some View {
            let palette = GlassPalette(colorScheme: colorScheme)
            configuration.label
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(foreground(palette))
                .padding(.horizontal, GlassMetric.spacingM)
                .padding(.vertical, 8)
                .background {
                    switch emphasis {
                    case .primary:
                        Capsule(style: .continuous).fill(palette.primaryGradient)
                    case .secondary:
                        // 浅色下 surfaceOverlay 与卡片同为淡白,按钮会隐形,改用控件实白底
                        Capsule(style: .continuous).fill(colorScheme == .dark ? palette.surfaceOverlay : palette.insetFill)
                    case .destructive:
                        Capsule(style: .continuous).fill(palette.danger.opacity(0.16))
                    }
                }
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(border(palette), lineWidth: 1)
                }
                .opacity(configuration.isPressed ? 0.82 : 1)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
        }

        private func foreground(_ palette: GlassPalette) -> Color {
            switch emphasis {
            case .primary: .white
            case .secondary: .primary
            case .destructive: palette.danger
            }
        }

        private func border(_ palette: GlassPalette) -> Color {
            switch emphasis {
            case .primary: palette.primaryStart.opacity(0.72)
            case .secondary: palette.border
            case .destructive: palette.danger.opacity(0.45)
            }
        }
    }
}

struct GlassIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GlassIconButtonBody(configuration: configuration)
    }

    private struct GlassIconButtonBody: View {
        @Environment(\.colorScheme) private var colorScheme
        let configuration: ButtonStyle.Configuration

        var body: some View {
            let palette = GlassPalette(colorScheme: colorScheme)
            configuration.label
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill(colorScheme == .dark ? palette.surfaceOverlay : palette.insetFill)
                }
                .overlay {
                    Circle().stroke(palette.border, lineWidth: 1)
                }
                .opacity(configuration.isPressed ? 0.78 : 1)
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
        }
    }
}

struct StatusBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    let status: GlassStatus
    let title: String?

    init(_ status: GlassStatus, title: String? = nil) {
        self.status = status
        self.title = title
    }

    var body: some View {
        let palette = GlassPalette(colorScheme: colorScheme)
        let tint = palette.color(for: status)
        Label(title ?? status.title, systemImage: status.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(tint.opacity(0.14)))
            .accessibilityLabel(status.accessibilityLabel)
    }
}

struct ActivityPulse: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    let isActive: Bool
    let color: Color

    init(isActive: Bool, color: Color) {
        self.isActive = isActive
        self.color = color
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.22))
                .frame(width: expanded ? 26 : 14, height: expanded ? 26 : 14)
                .opacity(expanded ? 0.12 : 0.72)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
        .onAppear(perform: updateAnimation)
        .onChange(of: isActive) { _, _ in updateAnimation() }
        .onChange(of: reduceMotion) { _, _ in updateAnimation() }
        .onDisappear { stopAnimation() }
    }

    private func updateAnimation() {
        guard isActive, !reduceMotion else {
            stopAnimation()
            return
        }
        expanded = false
        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: false)) {
            expanded = true
        }
    }

    private func stopAnimation() {
        withAnimation(nil) {
            expanded = false
        }
    }
}
