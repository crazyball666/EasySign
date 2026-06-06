import SwiftUI

struct ResignTool: Tool {
    let displayName = "重签"
    let subtitle = "为 IPA 重签名并导出"
    let icon = "signature"
    let accentColor = Color.blue
    let category: ToolCategory = .frequent
    let sortOrder = 0

    var requiredServices: Set<ServiceKey> { [.logger, .settings, .artifact] }

    func makeContentView(hub: ServiceHub) -> AnyView {
        // 阶段 5 之前临时：直接用现有 view，待阶段 3 改造
        AnyView(ResignContentView())
    }
}
