import SwiftUI

public struct ProgressTimeline: View {
    @Environment(\.colorScheme) private var colorScheme
    let stages: [ResignStage]
    let currentIndex: Int
    let failedIndex: Int?

    public init(stages: [ResignStage] = ResignStage.allCases,
                currentIndex: Int,
                failedIndex: Int? = nil) {
        self.stages = stages
        self.currentIndex = currentIndex
        self.failedIndex = failedIndex
    }

    public var body: some View {
        let palette = GlassPalette(colorScheme: colorScheme)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                ForEach(0..<stages.count, id: \.self) { i in
                    Rectangle()
                        .fill(color(for: i))
                        .frame(height: 6)
                        .cornerRadius(2)
                }
            }
            HStack(spacing: 0) {
                ForEach(0..<stages.count, id: \.self) { i in
                    Text(stages[i].rawValue)
                        .font(.system(size: 9))
                        .foregroundStyle(i <= currentIndex ? Color.primary : palette.mutedText)
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        }
    }

    private func color(for index: Int) -> Color {
        let palette = GlassPalette(colorScheme: colorScheme)
        if let failed = failedIndex, index == failed { return palette.danger }
        if index < currentIndex { return palette.success }
        if index == currentIndex { return palette.primaryStart }
        return palette.mutedBorder
    }
}
