import SwiftUI

enum ResignActivitySummary {
    static func rewriteCount(in messages: [String]) -> Int {
        messages.filter { message in
            message.hasPrefix("zsign entitlement ") &&
                (message.contains("移除：") || message.contains("改写："))
        }.count
    }
}

struct ResignStageHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    let index: Int
    let title: String
    let detail: String

    var body: some View {
        let palette = GlassPalette(colorScheme: colorScheme)
        HStack(spacing: GlassMetric.spacingS) {
            Text(String(format: "%02d", index))
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Capsule().fill(palette.primaryGradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline.weight(.bold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

struct ResignSummaryRow: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: GlassMetric.spacingS) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
