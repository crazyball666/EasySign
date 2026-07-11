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
        colorScheme == .dark ? Color.white.opacity(0.065) : Color.white.opacity(0.64)
    }

    var surfaceOverlay: Color {
        colorScheme == .dark ? Color.white.opacity(0.085) : Color.white.opacity(0.74)
    }

    var insetFill: Color {
        colorScheme == .dark ? Color.black.opacity(0.18) : Color.black.opacity(0.045)
    }

    var border: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.white.opacity(0.88)
    }

    var mutedBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.075)
    }

    var primaryStart: Color { Color(red: 0.30, green: 0.91, blue: 0.76) }
    var primaryEnd: Color { Color(red: 0.55, green: 0.43, blue: 0.96) }
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

        content
            .padding(padding ?? 0)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(fill)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(tone == .inset ? palette.mutedBorder : palette.border, lineWidth: 1)
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
                        Capsule(style: .continuous).fill(palette.surfaceOverlay)
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
                    Circle().fill(palette.surfaceOverlay)
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

    init(isActive: Bool, color: Color = Color.accentColor) {
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
