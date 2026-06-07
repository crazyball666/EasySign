import SwiftUI

struct TransferTool: Tool {
    let displayName = "互传"
    let subtitle = "两台电脑互传文本/文件/图片"
    let icon = "arrow.left.arrow.right"
    let accentColor = Color.teal
    let category: ToolCategory = .frequent
    let sortOrder = 2

    var requiredServices: Set<ServiceKey> { [.transfer, .logger] }

    func makeContentView(hub: ServiceHub) -> AnyView {
        AnyView(TransferToolView(service: hub.transfer))
    }
}
