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
                        // 680 = 各工具固定横排的最大需求(二维码:预览 340 + 操作列 220
                        // + 间距/边距 100 = 660)+ 缓冲;同时顶住侧栏分隔条把内容挤窄。
                        .frame(minWidth: 680, minHeight: 400)
                }
                .animation(detailAnimation, value: selection)
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .modifier(GlassWindowToolbarStyle())
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

/// Integrates the automatic NavigationSplitView toolbar with the Glass canvas.
/// macOS 15 adds removal of the generated title item; macOS 14 still loses the
/// opaque toolbar background while retaining its native title presentation.
private struct GlassWindowToolbarStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .toolbar(removing: .title)
                .toolbarBackground(.hidden, for: .windowToolbar)
        } else {
            content
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
    }
}
