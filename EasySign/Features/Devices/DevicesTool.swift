import SwiftUI

struct DevicesTool: Tool {
    let displayName = "设备"
    let subtitle = "浏览已连接 iOS 设备的文件"
    let icon = "iphone"
    let accentColor = Color.purple
    let category: ToolCategory = .frequent
    let sortOrder = 2

    var requiredServices: Set<ServiceKey> { [.logger] }

    func makeContentView(hub: ServiceHub) -> AnyView {
        AnyView(DeviceView())
    }
}
