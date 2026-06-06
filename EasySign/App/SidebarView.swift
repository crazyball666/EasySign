import SwiftUI

struct SidebarView: View {
    @Binding var selection: String?
    let tools: [any Tool]

    var body: some View {
        List(selection: $selection) {
            ForEach(ToolCategory.allCases) { category in
                let categoryTools = tools.filter { $0.category == category }
                    .sorted { $0.sortOrder < $1.sortOrder }
                if !categoryTools.isEmpty {
                    Section(category.rawValue) {
                        ForEach(categoryTools, id: \.id) { tool in
                            SidebarRow(tool: tool)
                                .tag(tool.id as String?)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
    }
}

private struct SidebarRow: View {
    let tool: any Tool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.displayName)
                    .font(.body)
                Text(tool.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: tool.icon)
                .foregroundStyle(tool.accentColor)
        }
    }
}
