import SwiftUI

struct WorkspaceHeader<Trailing: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let icon: String
    let title: String
    let subtitle: String
    let status: GlassStatus?
    let statusTitle: String?
    private let trailing: Trailing

    init(
        icon: String,
        title: String,
        subtitle: String,
        status: GlassStatus? = nil,
        statusTitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.statusTitle = statusTitle
        self.trailing = trailing()
    }

    var body: some View {
        let palette = GlassPalette(colorScheme: colorScheme)
        HStack(alignment: .center, spacing: GlassMetric.spacingM) {
            ZStack {
                RoundedRectangle(cornerRadius: GlassMetric.radiusMedium, style: .continuous)
                    .fill(palette.primaryGradient)
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.bold))
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(palette.mutedText)
                    .lineLimit(1)
                if let status {
                    StatusBadge(status, title: statusTitle)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: GlassMetric.spacingM)
            trailing
        }
        .glassSurface(.standard, radius: GlassMetric.radiusLarge, padding: GlassMetric.spacingL)
    }
}

extension WorkspaceHeader where Trailing == EmptyView {
    init(
        icon: String,
        title: String,
        subtitle: String,
        status: GlassStatus? = nil,
        statusTitle: String? = nil
    ) {
        self.init(
            icon: icon,
            title: title,
            subtitle: subtitle,
            status: status,
            statusTitle: statusTitle
        ) {
            EmptyView()
        }
    }
}

struct ContextRail<Content: View>: View {
    let title: String
    let subtitle: String?
    private let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GlassMetric.spacingL) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.bold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(.emphasized, radius: GlassMetric.radiusLarge, padding: GlassMetric.spacingL)
    }
}

struct GlassSectionTitle: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let icon: String
    let detail: String?

    init(_ title: String, icon: String, detail: String? = nil) {
        self.title = title
        self.icon = icon
        self.detail = detail
    }

    var body: some View {
        let palette = GlassPalette(colorScheme: colorScheme)
        HStack(spacing: GlassMetric.spacingS) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(palette.primaryStart)
                .frame(width: 18)
            Text(title)
                .font(.headline.weight(.semibold))
            Spacer(minLength: 0)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ActivityCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let detail: String
    let status: GlassStatus
    let progress: Double?

    init(title: String, detail: String, status: GlassStatus, progress: Double? = nil) {
        self.title = title
        self.detail = detail
        self.status = status
        self.progress = progress
    }

    var body: some View {
        let palette = GlassPalette(colorScheme: colorScheme)
        let tint = palette.color(for: status)
        HStack(alignment: .top, spacing: GlassMetric.spacingM) {
            if status.isAnimated {
                ActivityPulse(isActive: true, color: tint)
            } else {
                Image(systemName: status.symbol)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(palette.mutedText)
                    .lineLimit(2)
                if let progress {
                    ProgressView(value: progress)
                        .tint(tint)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(.inset, radius: GlassMetric.radiusMedium, padding: GlassMetric.spacingM)
        .accessibilityElement(children: .combine)
    }
}

struct GlassInspectorButton<Content: View>: View {
    @State private var isPresented = false
    let title: String
    private let content: Content

    init(title: String = "检查器", @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label(title, systemImage: "sidebar.right")
        }
        .buttonStyle(GlassButtonStyle())
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            content
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
                .padding(GlassMetric.spacingM)
        }
        .accessibilityLabel("打开\(title)")
    }
}
