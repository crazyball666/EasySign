import SwiftUI

struct ResignPrimaryAction: View {
    let isRunning: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(isRunning ? "重签进行中" : "开始重签", systemImage: isRunning ? "hourglass" : "play.fill")
                .frame(minWidth: 116)
        }
        .buttonStyle(GlassButtonStyle(.primary))
        .disabled(isRunning)
        .accessibilityHint(isRunning ? "当前重签任务尚未完成" : "开始当前配置的重签任务")
    }
}
