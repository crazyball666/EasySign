import SwiftUI

struct DeviceConnectionRail: View {
    let device: Device?
    let mode: BrowseMode

    var body: some View {
        ContextRail(title: "设备上下文", subtitle: "当前浏览目标") {
            if let device {
                ResignSummaryRow(label: "设备", value: device.name, icon: "iphone")
                ResignSummaryRow(label: "系统", value: device.systemVersion, icon: "gearshape")
                ResignSummaryRow(label: "连接", value: device.interfaceType == .wireless ? "无线" : "有线", icon: device.interfaceType == .wireless ? "wifi" : "cable.connector")
                ResignSummaryRow(label: "内容", value: mode == .apps ? "应用沙盒" : "媒体文件", icon: mode == .apps ? "app.badge" : "photo.on.rectangle")
                ActivityCard(title: "设备已选中", detail: "文件操作仍按现有 AFC 单批流程执行。", status: .success)
            } else {
                ActivityCard(title: "等待设备", detail: "连接 iOS 设备后从列表选择。", status: .idle)
            }
        }
    }
}
