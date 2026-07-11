import SwiftUI

struct SidebarView: View {
    @Binding var selection: String?
    let tools: [any Tool]
    let mode: GlassSidebarMode

    var body: some View {
        VStack(spacing: GlassMetric.spacingS) {
            brandHeader

            List(selection: $selection) {
                ForEach(ToolCategory.allCases) { category in
                    let categoryTools = tools.filter { $0.category == category }
                        .sorted { $0.sortOrder < $1.sortOrder }
                    if !categoryTools.isEmpty {
                        Section(mode == .labelledRail ? category.rawValue : "") {
                            ForEach(categoryTools, id: \.id) { tool in
                                SidebarRow(tool: tool, mode: mode)
                                    .tag(tool.id as String?)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .padding(mode == .labelledRail ? GlassMetric.spacingS : 5)
        .glassSurface(.emphasized, radius: GlassMetric.radiusLarge, padding: 0)
        .padding(.vertical, GlassMetric.spacingS)
        .padding(.leading, GlassMetric.spacingS)
        .frame(
            minWidth: mode == .labelledRail ? 208 : 66,
            idealWidth: mode == .labelledRail ? 242 : 66,
            maxWidth: mode == .labelledRail ? 320 : 72
        )
    }

    @ViewBuilder
    private var brandHeader: some View {
        if mode == .labelledRail {
            HStack(spacing: GlassMetric.spacingS) {
                Image(systemName: "signature")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(GlassPalette(colorScheme: .dark).primaryGradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text("EasySign")
                        .font(.headline.weight(.bold))
                    Text("Signal Glass")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, GlassMetric.spacingS)
            .padding(.top, GlassMetric.spacingS)
        } else {
            Image(systemName: "signature")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(GlassPalette(colorScheme: .dark).primaryGradient))
                .padding(.top, GlassMetric.spacingS)
                .accessibilityLabel("EasySign")
        }
    }
}

private struct SidebarRow: View {
    let tool: any Tool
    let mode: GlassSidebarMode

    var body: some View {
        HStack(spacing: GlassMetric.spacingS) {
            Image(systemName: tool.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tool.accentColor)
                .frame(width: 22, height: 22)

            if mode == .labelledRail {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.displayName)
                        .font(.body.weight(.medium))
                    Text(tool.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: mode == .labelledRail ? .leading : .center)
        .padding(.vertical, mode == .labelledRail ? 3 : 5)
        .accessibilityLabel("\(tool.displayName)，\(tool.subtitle)")
        .help(tool.displayName)
    }
}
