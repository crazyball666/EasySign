import SwiftUI

struct TransferToolView: View {
    @ObservedObject var service: TransferService

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 40))
                .foregroundStyle(.teal)
            Text("互传").font(.title2.bold())
            Text("Phase 1 开发中").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
