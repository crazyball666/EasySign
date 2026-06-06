import SwiftUI

public struct ProgressTimeline: View {
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
                        .foregroundStyle(i <= currentIndex ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        }
    }

    private func color(for index: Int) -> Color {
        if let failed = failedIndex, index == failed { return .red }
        if index < currentIndex { return .green }
        if index == currentIndex { return .blue }
        return Color.gray.opacity(0.25)
    }
}
