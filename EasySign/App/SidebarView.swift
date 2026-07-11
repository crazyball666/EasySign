import SwiftUI

struct SidebarView: View {
    @Binding var selection: String?
    let tools: [any Tool]
    let mode: GlassSidebarMode
    @FocusState private var focusedToolID: String?

    var body: some View {
        VStack(spacing: GlassMetric.spacingS) {
            brandHeader

            ScrollView {
                LazyVStack(alignment: .leading, spacing: mode == .labelledRail ? GlassMetric.spacingM : GlassMetric.spacingS) {
                ForEach(ToolCategory.allCases) { category in
                    let categoryTools = tools.filter { $0.category == category }
                        .sorted { $0.sortOrder < $1.sortOrder }
                    if !categoryTools.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            if mode == .labelledRail {
                                Text(category.rawValue)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, GlassMetric.spacingS)
                            }
                            ForEach(categoryTools, id: \.id) { tool in
                                Button {
                                    select(tool.id)
                                } label: {
                                    SidebarRow(
                                        tool: tool,
                                        mode: mode,
                                        isSelected: selection == tool.id
                                    )
                                }
                                .buttonStyle(.plain)
                                .focused($focusedToolID, equals: tool.id)
                                .accessibilityAddTraits(selection == tool.id ? .isSelected : [])
                                .accessibilityValue(selection == tool.id ? "已选中" : "未选中")
                            }
                        }
                    }
                }
                }
                .padding(.horizontal, mode == .labelledRail ? 4 : 0)
                .padding(.bottom, GlassMetric.spacingS)
            }
            .scrollIndicators(.hidden)
            .onMoveCommand { direction in
                switch direction {
                case .up:
                    moveSelection(.up)
                case .down:
                    moveSelection(.down)
                default:
                    break
                }
            }
        }
        .padding(mode == .labelledRail ? GlassMetric.spacingS : 5)
        .padding(.vertical, GlassMetric.spacingS)
        .padding(.leading, GlassMetric.spacingS)
        .frame(
            minWidth: mode == .labelledRail ? 208 : 66,
            idealWidth: mode == .labelledRail ? 242 : 66,
            maxWidth: mode == .labelledRail ? 320 : 72
        )
        .glassSidebarRail()
        .onAppear {
            focusedToolID = selection ?? navigationTools.first?.id
        }
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

    private var navigationTools: [any Tool] {
        ToolCategory.allCases.flatMap { category in
            tools.filter { $0.category == category }
                .sorted { $0.sortOrder < $1.sortOrder }
        }
    }

    private func moveSelection(_ direction: GlassSidebarMoveDirection) {
        guard let nextID = GlassSidebarNavigation.selection(
            afterMovingFrom: selection,
            in: navigationTools.map(\.id),
            direction: direction
        ) else { return }
        select(nextID)
    }

    private func select(_ toolID: String) {
        selection = toolID
        focusedToolID = toolID
    }
}

private struct SidebarRow: View {
    let tool: any Tool
    let mode: GlassSidebarMode
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let selectedFillOpacity = GlassSidebarRecipe.selectedFillOpacity(for: colorScheme)
        let selectedFill = Color.white.opacity(selectedFillOpacity)
        let selectedBorder = Color.white.opacity(GlassSidebarRecipe.selectedBorderOpacity(for: colorScheme))

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
        .padding(.horizontal, mode == .labelledRail ? GlassMetric.spacingS : 4)
        .padding(.vertical, mode == .labelledRail ? 7 : 6)
        .contentShape(RoundedRectangle(cornerRadius: GlassMetric.radiusSmall, style: .continuous))
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: GlassMetric.radiusSmall, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [selectedFill, Color.white.opacity(selectedFillOpacity * 0.88)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: GlassMetric.radiusSmall, style: .continuous)
                            .stroke(selectedBorder, lineWidth: 1)
                    }
                    .shadow(
                        color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.09),
                        radius: 7,
                        y: 3
                    )
            }
        }
        .animation(.easeOut(duration: 0.18), value: isSelected)
        .accessibilityLabel("\(tool.displayName)，\(tool.subtitle)")
        .help(tool.displayName)
    }
}
