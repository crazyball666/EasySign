import SwiftUI

// Shared back button used by SandboxBrowserView, FilePreviewView, and any other
// sub-view that needs a "← 返回" affordance. Keeps the chevron/text spacing and
// font consistent across the app.
struct BackButton: View {
    let action: () -> Void
    var isDisabled: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: "chevron.left")
                Text("返回")
            }
        }
        .disabled(isDisabled)
    }
}
