import Foundation

enum GlassSidebarMode: Equatable {
    case labelledRail
    case iconRail
    case systemCollapsed

    var accessibilityLabel: String {
        switch self {
        case .labelledRail: "完整导航"
        case .iconRail: "仅图标导航"
        case .systemCollapsed: "系统折叠导航"
        }
    }
}

enum GlassContextPresentation: Equatable {
    case rail
    case inspector

    var accessibilityLabel: String {
        switch self {
        case .rail: "上下文栏"
        case .inspector: "检查器"
        }
    }
}

enum GlassSidebarMoveDirection {
    case up
    case down
}

enum GlassSidebarNavigation {
    static func selection(
        afterMovingFrom currentID: String?,
        in navigationIDs: [String],
        direction: GlassSidebarMoveDirection
    ) -> String? {
        guard let firstID = navigationIDs.first else { return nil }
        guard let currentID, let currentIndex = navigationIDs.firstIndex(of: currentID) else {
            return firstID
        }

        switch direction {
        case .up:
            return navigationIDs[max(0, currentIndex - 1)]
        case .down:
            return navigationIDs[min(navigationIDs.count - 1, currentIndex + 1)]
        }
    }
}

enum GlassLayout {
    static func sidebarMode(for width: CGFloat) -> GlassSidebarMode {
        if width < 700 { return .systemCollapsed }
        if width < 820 { return .iconRail }
        return .labelledRail
    }

    static func contextPresentation(for width: CGFloat) -> GlassContextPresentation {
        width < 1180 ? .inspector : .rail
    }
}
