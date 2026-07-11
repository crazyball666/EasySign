import SwiftUI

enum ConflictResolution {
    case overwrite
    case rename
    case skip
    case cancel
}

// Sheet shown when a file with the same name already exists at the destination.
// Batch operations can capture the "apply to all" decision so the user isn't
// prompted again for the remaining files in this batch.
struct ConflictResolutionSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    let conflictingName: String
    let remainingCount: Int   // how many MORE files in this batch could conflict
    let onResolve: (ConflictResolution, Bool /* applyToAll */) -> Void

    @State private var applyToAll: Bool = false

    var body: some View {
        GlassCanvas {
            VStack(alignment: .leading, spacing: GlassMetric.spacingL) {
                HStack(spacing: GlassMetric.spacingM) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(GlassPalette(colorScheme: colorScheme).warning)
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("文件冲突")
                            .font(.headline)
                        Text("目标位置已存在文件")
                            .font(.caption)
                            .foregroundStyle(GlassPalette(colorScheme: colorScheme).mutedText)
                    }
                    Spacer()
                }

                HStack(spacing: GlassMetric.spacingS) {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(GlassPalette(colorScheme: colorScheme).mutedText)
                    Text(conflictingName)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassSurface(.inset, radius: GlassMetric.radiusSmall, padding: GlassMetric.spacingS)

                if remainingCount > 0 {
                    Toggle("应用于后续冲突（剩余 \(remainingCount) 个文件）", isOn: $applyToAll)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }

                HStack(spacing: GlassMetric.spacingS) {
                    Button("取消") { onResolve(.cancel, false) }
                        .buttonStyle(GlassButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("跳过") { onResolve(.skip, applyToAll) }
                        .buttonStyle(GlassButtonStyle())
                    Button("重命名") { onResolve(.rename, applyToAll) }
                        .buttonStyle(GlassButtonStyle())
                    Button("覆盖") { onResolve(.overwrite, applyToAll) }
                        .buttonStyle(GlassButtonStyle(.primary))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .glassSurface(.emphasized, radius: GlassMetric.radiusLarge, padding: GlassMetric.spacingL)
            .padding(GlassMetric.spacingL)
        }
        .frame(width: 420)
    }
}

// Utility: given a target path that already exists, produce a non-conflicting
// alternative like "file (1).txt", "file (2).txt", ... by probing the device.
enum ConflictRenamer {
    static func renamedPath(
        directory: String,
        originalName: String,
        existsCheck: (String) -> Bool
    ) -> String {
        let ns = originalName as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var counter = 1
        while true {
            let candidate: String
            if ext.isEmpty {
                candidate = "\(base) (\(counter))"
            } else {
                candidate = "\(base) (\(counter)).\(ext)"
            }
            let fullPath = (directory as NSString).appendingPathComponent(candidate)
            if !existsCheck(fullPath) {
                return fullPath
            }
            counter += 1
            if counter > 999 { return fullPath }   // give up gracefully
        }
    }
}
