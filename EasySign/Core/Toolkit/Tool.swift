import SwiftUI

protocol Tool: Identifiable {
    var id: String { get }
    var displayName: String { get }
    var subtitle: String { get }
    var icon: String { get }
    var accentColor: Color { get }
    var category: ToolCategory { get }
    var sortOrder: Int { get }
    var requiredServices: Set<ServiceKey> { get }

    @ViewBuilder
    func makeContentView(hub: ServiceHub) -> AnyView
}

extension Tool {
    var id: String { String(describing: Self.self).lowercased() }
    var sortOrder: Int { 0 }
}
