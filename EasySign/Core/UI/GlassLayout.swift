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

enum GlassDeviceSelectorPresentation: Equatable {
    case rail
    case topPicker
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

    static func deviceSelectorPresentation(forDetailWidth width: CGFloat) -> GlassDeviceSelectorPresentation {
        width < 980 ? .topPicker : .rail
    }
}
