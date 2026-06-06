import Foundation
import Combine

/// 设备服务协议。注：当前为 internal，因为依赖的 AFCClient / DeviceManager 是 internal。
/// 当这些类型升级为 public 时，可以升级 DeviceServiceProtocol 为 public。
protocol DeviceServiceProtocol {
    var devices: AnyPublisher<[PairedDevice], Never> { get }
    func connect(_ device: PairedDevice) -> Bool
    func disconnect()
    func afcClient(for device: PairedDevice) -> AFCClient?
    func installIPA(_ ipa: URL, on device: PairedDevice) -> AsyncThrowingStream<InstallEvent, Error>
}

/// DeviceService 是 Core 层对 DeviceManager 的轻量包装，提供 PairedDevice 抽象和
/// installIPA 入口。被 ServiceHub 持有。
final class DeviceService: DeviceServiceProtocol {
    static let shared = DeviceService()

    private let manager: DeviceManager

    init(manager: DeviceManager = .shared) {
        self.manager = manager
    }

    var devices: AnyPublisher<[PairedDevice], Never> {
        manager.$devices
            .map { $0.map { PairedDevice(id: $0.id, name: $0.name, model: $0.model, osVersion: $0.systemVersion) } }
            .eraseToAnyPublisher()
    }

    func connect(_ device: PairedDevice) -> Bool {
        // 将 PairedDevice 映射回内部 Device
        guard let internalDevice = manager.devices.first(where: { $0.id == device.id }) else {
            return false
        }
        return manager.connect(to: internalDevice)
    }

    func disconnect() {
        manager.disconnect()
    }

    func afcClient(for device: PairedDevice) -> AFCClient? {
        // 阶段 4 占位：现有 DeviceManager 没有按 device 拿 afcClient 的方法。
        // Devices 工具通过 DeviceManager 内部连接状态访问。
        return nil
    }

    func installIPA(_ ipa: URL, on device: PairedDevice) -> AsyncThrowingStream<InstallEvent, Error> {
        // 阶段 4 占位：完整 installIPA 实现需要 installation_proxy 服务，
        // 现有 Devices tab 没有这个能力。返回单事件流表示"未实现"。
        AsyncThrowingStream { continuation in
            continuation.yield(InstallEvent(stage: "未实现", progress: 0, message: "installIPA 将在阶段 6 实现"))
            continuation.finish()
        }
    }
}
