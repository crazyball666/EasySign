import SwiftUI

struct RootView: View {
    @State private var selection: String?
    @State private var hub: ServiceHub

    init(hub: ServiceHub) {
        _hub = State(initialValue: hub)
        _selection = State(initialValue: Self.initialSelection(settings: hub.settings))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, tools: ToolRegistry.allTools)
        } detail: {
            detailView
                .frame(minWidth: 600, minHeight: 400)
        }
        .safeAreaInset(edge: .bottom) {
            StatusBar(currentTool: currentTool, artifactStore: hub.artifact)
        }
        .frame(minWidth: 750, minHeight: 670)  // 保持原有固定窗口尺寸
        .onChange(of: selection) { _, newValue in
            // 记住最后选中的工具,供下次启动按「启动时恢复上次工具」恢复
            if let id = newValue { hub.settings.set(id, for: .lastActiveTool) }
        }
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
