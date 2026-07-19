import AppKit
import Combine

/// App 真实图标的按需加载 + 缓存。
///
/// 为什么不在 AppLister 里一次性拉完:每个图标是一次独立 RPC 往返,一台设备三百多个 App
/// 全拉一遍既慢又白费(列表一次只看得见十来行)。这里改成行出现时才请求,结果按 bundleID
/// 缓存在内存里,同一 bundleID 并发请求只发一次。
@MainActor
final class AppIconStore: ObservableObject {
    /// bundleID → 图标。仅在主线程变更。
    @Published private(set) var icons: [String: NSImage] = [:]

    /// 已经请求过的 bundleID(含失败的),避免对没有图标的 App 反复重试。
    private var requested: Set<String> = []
    private let fetcher = IconFetcher()

    /// 设备变了就把缓存和连接全部作废 —— 图标是跟着设备走的。
    func reset(deviceID: String?) {
        icons = [:]
        requested = []
        fetcher.invalidate()
    }

    /// 请求某个 App 的图标。已缓存或已请求过则直接返回,不重复发。
    func load(for app: InstalledApp) {
        guard !requested.contains(app.bundleID) else { return }
        requested.insert(app.bundleID)

        let bundleID = app.bundleID
        let deviceID = app.device.id
        fetcher.fetch(bundleID: bundleID, deviceID: deviceID) { [weak self] image in
            guard let image else { return }
            Task { @MainActor in self?.icons[bundleID] = image }
        }
    }
}

/// 图标抓取的后台侧。独立于 @MainActor 的 AppIconStore —— 一条 springboardservices
/// 连接不能并发读写,所有 RPC 串行跑在私有队列上。
private final class IconFetcher {
    private let queue = DispatchQueue(label: "AppIconStore.fetch", qos: .utility)
    /// 只在 queue 上访问。
    private var client: SpringBoardServicesClient?

    func invalidate() {
        queue.async { [weak self] in self?.client = nil }
    }

    func fetch(bundleID: String, deviceID: String, completion: @escaping (NSImage?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return completion(nil) }
            guard let data = self.fetchData(bundleID: bundleID, deviceID: deviceID) else {
                return completion(nil)
            }
            completion(NSImage(data: data))
        }
    }

    private func fetchData(bundleID: String, deviceID: String) -> Data? {
        if let data = try? connectedClient(deviceID: deviceID)?.iconPNGData(bundleID: bundleID) {
            return data
        }
        // 连接可能在设备重连/服务超时后失效,丢弃重建一次再试。
        client = nil
        return try? connectedClient(deviceID: deviceID)?.iconPNGData(bundleID: bundleID)
    }

    private func connectedClient(deviceID: String) -> SpringBoardServicesClient? {
        if let client { return client }
        guard let deviceRef = DeviceManager.shared.getConnectedDeviceRef(for: deviceID) else { return nil }
        client = try? SpringBoardServicesClient(deviceRef: deviceRef)
        return client
    }
}
