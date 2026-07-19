import Foundation

// MARK: - Errors

enum SpringBoardServicesError: LocalizedError {
    case startServiceFailed(Int32)
    case sendFailed(errno: Int32)
    case recvFailed(errno: Int32)
    case badReply
    case noIconData

    var errorDescription: String? {
        switch self {
        case .startServiceFailed(let c): return "无法启动 springboardservices 服务(code \(c))"
        case .sendFailed(let e):         return "发送图标请求失败(errno \(e))"
        case .recvFailed(let e):         return "接收图标数据失败(errno \(e))"
        case .badReply:                  return "图标回复格式异常"
        case .noIconData:                return "该 App 没有可用图标"
        }
    }
}

// MARK: - SpringBoardServicesClient
//
// com.apple.springboardservices 与 installation_proxy 同属 lockdownd 的 plist-RPC 服务
// (4 字节大端长度前缀 + XML plist,编码见 AMDPlistCodec)。它是唯一能拿到**真实 App 图标**
// 的途径:installation_proxy 的 CFBundleIcons 只给文件名,house_arrest 又进不去 .app 包。
//
// 与 InstallationProxyClient 的差别:那两个命令是「一发一收就结束」,这里一条连接可以连续
// 问很多个 bundleID(实测有效),所以做成实例而非 enum —— 列表里几十个 App 各开一次 SSL
// 服务的握手开销完全没必要。
final class SpringBoardServicesClient {
    static let serviceName = "com.apple.springboardservices"

    private let connection: AMDServiceConnectionRef

    init(deviceRef: AMDeviceRef) throws {
        let (result, conn) = ServiceConnectionIO.secureStartWithRetry(deviceRef: deviceRef, service: Self.serviceName)
        guard result == AMDAppLEDETECT_SUCCESS, let c = conn else {
            throw SpringBoardServicesError.startServiceFailed(result)
        }
        connection = c
    }

    deinit {
        AMDServiceConnectionInvalidate(connection)
    }

    /// 取指定 bundleID 的主屏图标 PNG(实测 192×192,圆角已由 SpringBoard 烘焙进去)。
    func iconPNGData(bundleID: String) throws -> Data {
        let reply = try rpc(["command": "getIconPNGData", "bundleId": bundleID])
        guard let png = reply["pngData"] as? Data, !png.isEmpty else {
            throw SpringBoardServicesError.noIconData
        }
        return png
    }

    // MARK: - Private

    private func rpc(_ request: [String: Any]) throws -> [String: Any] {
        let buffer: Data
        do { buffer = try AMDPlistCodec.frame(request) } catch { throw SpringBoardServicesError.badReply }
        guard ServiceConnectionIO.sendAll(connection, buffer) else {
            throw SpringBoardServicesError.sendFailed(errno: errno)
        }

        var prefix = [UInt8](repeating: 0, count: 4)
        try prefix.withUnsafeMutableBufferPointer { try readExact(into: $0.baseAddress!, count: 4) }
        // 图标 PNG 比 plist 回复大得多,上限放宽到 32MB(installation_proxy 那边是 10MB)。
        guard let bodyLen = AMDPlistCodec.bodyLength(prefix: Data(prefix)), bodyLen > 0, bodyLen < 32_000_000 else {
            throw SpringBoardServicesError.badReply
        }
        var body = [UInt8](repeating: 0, count: bodyLen)
        try body.withUnsafeMutableBufferPointer { try readExact(into: $0.baseAddress!, count: bodyLen) }
        guard let dict = try? PropertyListSerialization.propertyList(from: Data(body), options: [], format: nil) as? [String: Any] else {
            throw SpringBoardServicesError.badReply
        }
        return dict
    }

    private func readExact(into ptr: UnsafeMutableRawPointer, count: Int) throws {
        guard ServiceConnectionIO.recvExact(connection, into: ptr, count: count) == .ok else {
            throw SpringBoardServicesError.recvFailed(errno: errno)
        }
    }
}
