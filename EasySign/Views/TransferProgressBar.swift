import SwiftUI

// What kind of transfer is happening — controls icon + color + verb.
enum TransferKind: Equatable {
    case download
    case upload
    case copy
    case move
    case delete
}

// State machine for one (possibly multi-file) transfer in flight. Used by
// SandboxBrowserView and FilePreviewView; the bar at the bottom renders this.
//
// Lifecycle: idle → inProgress → succeeded → idle (auto-dismiss after 2s)
//            on error: → idle (caller surfaces error elsewhere)
enum TransferState: Equatable {
    case idle
    case inProgress(
        kind: TransferKind,
        currentFile: String,
        currentIndex: Int,
        totalFiles: Int,
        bytes: UInt64,
        total: UInt64?
    )
    case succeeded(kind: TransferKind, summary: String)

    var isActive: Bool {
        if case .idle = self { return false }
        return true
    }

    var isInProgress: Bool {
        if case .inProgress = self { return true }
        return false
    }
}

struct TransferProgressBar: View {
    let state: TransferState

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            // Opaque background so the content (image preview / file list)
            // doesn't bleed through. controlBackgroundColor adapts to dark
            // mode; success state layers a green tint on top.
            .background(
                ZStack {
                    Color(NSColor.controlBackgroundColor)
                    if case .succeeded = state {
                        Color.green.opacity(0.18)
                    }
                }
            )
            .overlay(Divider(), alignment: .top)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            EmptyView()

        case .inProgress(let kind, let file, let index, let total, let bytes, let totalBytes):
            HStack(spacing: 10) {
                Image(systemName: kind.iconName)
                    .foregroundColor(kind.tint)

                // "3/10: filename" when batching, just "filename" when single.
                Text(batchPrefix(index: index, total: total) + file)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 200, alignment: .leading)

                if let totalBytes = totalBytes, totalBytes > 0 {
                    ProgressView(value: Double(bytes), total: Double(totalBytes))
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(progressLabel(bytes: bytes, total: totalBytes))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 110, alignment: .trailing)
            }

        case .succeeded(let kind, let summary):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("\(kind.successPrefix)：\(summary)")
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
        }
    }

    private func batchPrefix(index: Int, total: Int) -> String {
        guard total > 1 else { return "" }
        return "\(index)/\(total): "
    }

    private func progressLabel(bytes: UInt64, total: UInt64?) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let done = formatter.string(fromByteCount: Int64(bytes))
        if let total = total, total > 0 {
            let totalStr = formatter.string(fromByteCount: Int64(total))
            let pct = Int((Double(bytes) / Double(total)) * 100)
            return "\(done) / \(totalStr) (\(pct)%)"
        }
        return done
    }
}

extension TransferKind {
    var iconName: String {
        switch self {
        case .download: return "arrow.down.circle.fill"
        case .upload:   return "arrow.up.circle.fill"
        case .copy:     return "doc.on.doc.fill"
        case .move:     return "arrow.turn.up.right"
        case .delete:   return "trash.fill"
        }
    }

    var tint: Color {
        switch self {
        case .download: return .blue
        case .upload:   return .green
        case .copy:     return .purple
        case .move:     return .orange
        case .delete:   return .red
        }
    }

    var successPrefix: String {
        switch self {
        case .download: return "下载完成"
        case .upload:   return "上传完成"
        case .copy:     return "复制完成"
        case .move:     return "移动完成"
        case .delete:   return "删除完成"
        }
    }
}

// Shared helper for streamFile/uploadFile/copyFile progress callbacks. Coalesces
// UI updates to ~10Hz so a 1GB transfer doesn't spam main with 1000 hops.
final class TransferProgressThrottle {
    private var lastFired: Date = .distantPast

    func shouldFire(written: UInt64, total: UInt64?) -> Bool {
        let isFinal = (total.map { written >= $0 } ?? false)
        let now = Date()
        if isFinal || now.timeIntervalSince(lastFired) > 0.1 {
            lastFired = now
            return true
        }
        return false
    }
}

// Apply this to any view that owns a TransferState. Drives the success →
// idle auto-dismiss with a 2-second pause, both inside withAnimation.
extension View {
    func autoDismissTransferSuccess(_ state: Binding<TransferState>) -> some View {
        // Single-param onChange; the two-param replacement requires macOS 14
        // and our deployment target is 13.
        onChange(of: state.wrappedValue) { newValue in
            guard case .succeeded = newValue else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if case .succeeded = state.wrappedValue {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        state.wrappedValue = .idle
                    }
                }
            }
        }
    }
}
