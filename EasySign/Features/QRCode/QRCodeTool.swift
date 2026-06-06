import SwiftUI

struct QRCodeTool: Tool {
    let displayName = "二维码"
    let subtitle = "生成与扫描二维码"
    let icon = "qrcode"
    let accentColor = Color.green
    let category: ToolCategory = .frequent
    let sortOrder = 1

    var requiredServices: Set<ServiceKey> { [.logger] }

    func makeContentView(hub: ServiceHub) -> AnyView {
        AnyView(QRCodeToolView())
    }
}
