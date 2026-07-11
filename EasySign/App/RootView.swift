import SwiftUI

struct RootView: View {
    @State private var selection: String?
    @State private var hub: ServiceHub
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(hub: ServiceHub) {
        _hub = State(initialValue: hub)
        _selection = State(initialValue: Self.initialSelection(settings: hub.settings))
    }

    var body: some View {
        GlassCanvas {
            GeometryReader { proxy in
                let sidebarMode = GlassLayout.sidebarMode(for: proxy.size.width)
                NavigationSplitView {
                    SidebarView(
                        selection: $selection,
                        tools: ToolRegistry.allTools,
                        mode: sidebarMode
                    )
                } detail: {
                    detailView
                        .id(selection ?? "empty-tool")
                        .transition(detailTransition)
                        .frame(minWidth: 500, minHeight: 400)
                }
                .animation(detailAnimation, value: selection)
            }
        }
        .frame(minWidth: 620, minHeight: 620)
        .onChange(of: selection) { _, newValue in
            // 记住最后选中的工具,供下次启动按「启动时恢复上次工具」恢复
            if let id = newValue { hub.settings.set(id, for: .lastActiveTool) }
        }
    }

    private var detailTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .opacity.combined(with: .offset(x: 24))
    }

    private var detailAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.18) : .easeOut(duration: 0.38)
    }

    @ViewBuilder
    private var detailView: some View {
        if let tool = currentTool {
            tool.makeContentView(hub: hub)
        } else {
            Text("选择一个工具")
                .foregroundStyle(.secondary)
        }
    }

    private var currentTool: (any Tool)? {
        guard let id = selection else { return nil }
        return ToolRegistry.tool(forId: id)
    }

    /// 启动时的初始选中工具:开启「启动时恢复上次工具」且上次工具仍存在时恢复它,否则用第一个。
    private static func initialSelection(settings: SettingsStore) -> String? {
        if settings.bool(.launchRestoresLastTool),
           let saved = settings.string(.lastActiveTool),
           ToolRegistry.tool(forId: saved) != nil {
            return saved
        }
        return ToolRegistry.allTools.first?.id
    }
}
