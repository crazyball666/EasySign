import SwiftUI

struct StatusBar: View {
    let currentTool: (any Tool)?
    @ObservedObject var artifactStore: ArtifactStore

    var body: some View {
        HStack(spacing: 8) {
            if let tool = currentTool {
                Image(systemName: tool.icon)
                    .foregroundStyle(tool.accentColor)
                Text(tool.displayName)
                    .font(.caption)
            }
            Spacer()
            if let last = artifactStore.allArtifacts(limit: 1).first {
                StatusBadge(status: last.status)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .frame(height: 24)
    }
}

struct StatusBadge: View {
    let status: ResignArtifact.Status

    var body: some View {
        switch status {
        case .running:
            Label("进行中", systemImage: "circle.dotted").foregroundStyle(.blue)
        case .success:
            Label("成功", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure:
            Label("失败", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        case .canceled:
            Label("已取消", systemImage: "minus.circle").foregroundStyle(.secondary)
        }
    }
}
