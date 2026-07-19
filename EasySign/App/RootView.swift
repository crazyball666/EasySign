import SwiftUI

struct RootView: View {
    @State private var selection: String?
    @State private var hub: ServiceHub
    /// 由系统工具栏那颗 toggle 回写,用来判断详情列是不是成了最左列。
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(hub: ServiceHub) {
        _hub = State(initialValue: hub)
        _selection = State(initialValue: Self.initialSelection(settings: hub.settings))
    }

    private var sidebarHidden: Bool { columnVisibility == .detailOnly }

    var body: some View {
        GlassCanvas {
            GeometryReader { proxy in
                let sidebarMode = GlassLayout.sidebarMode(for: proxy.size.width)
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView(
                        selection: $selection,
                        tools: ToolRegistry.allTools,
                        mode: sidebarMode
                    )
                    .ignoresSafeArea(.container, edges: .top)
                } detail: {
                    detailView
                        .id(selection ?? "empty-tool")
                        .transition(detailTransition)
                        // 680 = 各工具固定横排的最大需求(二维码:预览 340 + 操作列 220
                        // + 间距/边距 100 = 660)+ 缓冲;同时顶住侧栏分隔条把内容挤窄。
                        .frame(minWidth: 680, minHeight: 400)
                        // 侧栏列本来就顶到窗口上沿(红绿灯浮在它上面),详情列却被工具栏
                        // 的安全区推下约 52pt,白出一条空带。这里让它也顶上去,顶部留白
                        // 改由 workspaceTopInset 说了算。
                        //
                        // 注意:窗口标题栏在内容之上,y < ~50pt 的区域点击会被它接走
                        // (变成拖窗口)。所以 workspaceTopInset 不能小到把可点控件
                        // (工作台头部右侧那颗按钮)顶进这条带里。
                        //
                        // 只在侧栏可见时顶上去。侧栏收起后详情列成了最左列,红绿灯和
                        // 工具栏那颗 toggle 都落在它头上 —— 实测会直接压在工作台标题上,
                        // 这种情况老老实实让安全区顶着。
                        .ignoresSafeArea(.container, edges: sidebarHidden ? [] : .top)
                }
                .animation(detailAnimation, value: selection)
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .modifier(GlassWindowToolbarStyle())
        .onChange(of: selection) { _, newValue in
            // 记住最后选中的工具,供下次启动按「启动时恢复上次工具」恢复
            if let id = newValue { hub.settings.set(id, for: .lastActiveTool) }
            clearInitialFocus()
        }
        .onAppear { clearInitialFocus() }
    }

    /// AppKit 会在窗口成 key / 内容重建时把第一个文本控件设为第一响应者
    /// (重签页会自动聚焦「证书密码」),启动与切换工具后主动清掉。
    private func clearInitialFocus() {
        DispatchQueue.main.async {
            let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible)
            window?.makeFirstResponder(nil)
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
///
/// 注意:不要改成 .toolbar(.hidden, for: .windowToolbar) —— 实测它会把标准
/// 窗口按钮(红绿灯)一起干掉,而工具栏保留的那块高度**并不会**释放。
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
