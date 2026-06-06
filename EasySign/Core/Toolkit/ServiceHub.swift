import Foundation
import AppKit

/// 共享服务容器。在 App 启动时构造（ServiceHub.live()），注入到所有 tool。
final class ServiceHub {
    let device: DeviceService
    let logger: LoggerService
    let recent: RecentFilesService
    let settings: SettingsStore
    let artifact: ArtifactStore

    init(device: DeviceService, logger: LoggerService,
         recent: RecentFilesService, settings: SettingsStore,
         artifact: ArtifactStore) {
        self.device = device
        self.logger = logger
        self.recent = recent
        self.settings = settings
        self.artifact = artifact
    }

    static func live() -> ServiceHub {
        let logger = LoggerService.live()
        let settings = SettingsStore()
        let recent = RecentFilesService()
        let artifact = ArtifactStore(logger: logger)
        let device = DeviceService.shared
        return ServiceHub(device: device, logger: logger, recent: recent,
                          settings: settings, artifact: artifact)
    }

    /// DEBUG 启动时调用，Release 不调用。
    /// 验证所有 tool 声明的服务都已注册。
    func validate() {
        #if DEBUG
        for tool in ToolRegistry.allTools {
            for key in tool.requiredServices {
                precondition(self[key] != nil, "工具 \(tool.id) 需要服务 \(key) 但未注册")
            }
        }
        #endif
    }

    subscript(key: ServiceKey) -> Any? {
        switch key {
        case .device: return device
        case .logger: return logger
        case .recent: return recent
        case .settings: return settings
        case .artifact: return artifact
        }
    }
}
