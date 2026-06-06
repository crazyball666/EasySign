import SwiftUI

struct RootView: View {
    @State private var selection: String? = ToolRegistry.allTools.first?.id
    @State private var hub: ServiceHub

    init(hub: ServiceHub) {
        _hub = State(initialValue: hub)
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
        .frame(minWidth: 900, minHeight: 600)
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
}
