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
    func uninstallApp(bundleID: String, on device: PairedDevice) -> AsyncThrowingStream<InstallEvent, Error>
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

    /// 安装 IPA:AFC 上传到 PublicStaging(占进度前 50%)→ installation_proxy 安装(后 50%)。
    /// 设备需已连接;后台队列执行,事件经 AsyncThrowingStream 上报 UI。
    func installIPA(_ ipa: URL, on device: PairedDevice) -> AsyncThrowingStream<InstallEvent, Error> {
        AsyncThrowingStream { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard let internalDevice = self.manager.devices.first(where: { $0.id == device.id }) else {
                        throw DeviceError.notConnected
                    }
                    guard let deviceRef = self.manager.getConnectedDeviceRef(for: device.id) else {
                        throw DeviceError.notConnected
                    }
                    // 1. AFC 上传到媒体分区 PublicStaging(已存在则忽略建目录错误)。
                    continuation.yield(InstallEvent(stage: "上传", progress: 0, message: "准备上传…"))
                    let afc = try AFCClient(device: internalDevice)
                    let remotePath = "PublicStaging/\(ipa.lastPathComponent)"
                    try? afc.createDirectory(at: "PublicStaging")
                    try afc.uploadFile(localURL: ipa, to: remotePath) { written, total in
                        let frac = (total.map { $0 > 0 ? Double(written) / Double($0) : 0 }) ?? 0
                        continuation.yield(InstallEvent(stage: "上传", progress: frac * 0.5,
                                                        message: "上传中 \(Int(frac * 100))%"))
                    }
                    // 2. installation_proxy 安装。
                    continuation.yield(InstallEvent(stage: "安装", progress: 0.5, message: "开始安装…"))
                    try InstallationProxyClient.install(deviceRef: deviceRef, devicePackagePath: remotePath) { reply in
                        if case let .progress(pct, status) = reply {
                            let frac = pct.map { Double($0) / 100.0 } ?? 0
                            continuation.yield(InstallEvent(stage: "安装", progress: 0.5 + frac * 0.5,
                                                            message: status ?? "安装中…"))
                        }
                    }
                    continuation.yield(InstallEvent(stage: "完成", progress: 1.0, message: "安装完成"))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// 卸载指定 bundleID(用户 App)。后台执行,事件经流上报。
    func uninstallApp(bundleID: String, on device: PairedDevice) -> AsyncThrowingStream<InstallEvent, Error> {
        AsyncThrowingStream { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard let deviceRef = self.manager.getConnectedDeviceRef(for: device.id) else {
                        throw DeviceError.notConnected
                    }
                    continuation.yield(InstallEvent(stage: "卸载", progress: 0, message: "开始卸载…"))
                    try InstallationProxyClient.uninstall(deviceRef: deviceRef, bundleID: bundleID) { reply in
                        if case let .progress(pct, status) = reply {
                            let frac = pct.map { Double($0) / 100.0 } ?? 0
                            continuation.yield(InstallEvent(stage: "卸载", progress: frac, message: status ?? "卸载中…"))
                        }
                    }
                    continuation.yield(InstallEvent(stage: "完成", progress: 1.0, message: "卸载完成"))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
