import Foundation

enum ToolRegistry {
    static let allTools: [any Tool] = [
        ResignTool(),
        QRCodeTool(),
        DevicesTool(),
        TransferTool(),
    ]

    static func tool(forId id: String) -> (any Tool)? {
        allTools.first { $0.id == id }
    }
}
