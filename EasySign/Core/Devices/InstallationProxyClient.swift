import Foundation

// MARK: - Errors

enum InstallationProxyError: LocalizedError {
    case startServiceFailed(Int32)
    case sendFailed(errno: Int32)
    case recvFailed(errno: Int32)
    case badReply
    case failed(String)     // installation_proxy 返回的 Error(签名/描述文件不匹配等)

    var errorDescription: String? {
        switch self {
        case .startServiceFailed(let c): return "无法启动 installation_proxy 服务(code \(c))"
        case .sendFailed(let e):         return "发送安装命令失败(errno \(e))"
        case .recvFailed(let e):         return "接收安装回复失败(errno \(e))"
        case .badReply:                  return "安装回复格式异常"
        case .failed(let m):             return m
        }
    }
}

// MARK: - InstallationProxyClient
//
// com.apple.mobile.installation_proxy 是 lockdownd 的 plist-RPC 服务(iOS 13+ 需 SSL)。
// 用 AMDeviceSecureStartService 起(自动配置 SSL),用 AMDServiceConnectionSend/Receive 收发
// 「4 字节大端长度前缀 + XML plist」(编码见 AMDPlistCodec)。Install/Uninstall 是流式:
// 发一次命令,循环读回复(进度),直到 Complete 或 Error。范式与 HouseArrestClient 一致。
enum InstallationProxyClient {
    static let serviceName = "com.apple.mobile.installation_proxy"

    /// 安装设备上已暂存的包(devicePackagePath 相对 AFC 媒体根,如 "PublicStaging/x.ipa")。
    static func install(deviceRef: AMDeviceRef, devicePackagePath: String,
                        onProgress: (InstallReply) -> Void) throws {
        let conn = try startService(deviceRef)
        defer { AMDServiceConnectionInvalidate(conn) }
        let req: [String: Any] = [
            "Command": "Install",
            "PackagePath": devicePackagePath,
            "ClientOptions": [String: Any](),   // .ipa 归档,无需 PackageType
        ]
        try send(req, over: conn)
        try drainReplies(conn, onProgress: onProgress)
    }

    /// 卸载指定 bundleID 的 App。
    static func uninstall(deviceRef: AMDeviceRef, bundleID: String,
                          onProgress: (InstallReply) -> Void) throws {
        let conn = try startService(deviceRef)
        defer { AMDServiceConnectionInvalidate(conn) }
        let req: [String: Any] = ["Command": "Uninstall", "ApplicationIdentifier": bundleID]
        try send(req, over: conn)
        try drainReplies(conn, onProgress: onProgress)
    }

    // MARK: - Private

    /// 循环读回复:.progress 回调上去,.complete 收尾,.failed 抛错。
    private static func drainReplies(_ conn: AMDServiceConnectionRef,
                                     onProgress: (InstallReply) -> Void) throws {
        while true {
            let dict = try recv(from: conn)
            switch InstallReply.interpret(dict) {
            case .complete:
                onProgress(.complete); return
            case .failed(let msg):
                throw InstallationProxyError.failed(msg)
            case let .progress(pct, status):
                onProgress(.progress(percent: pct, status: status))
            }
        }
    }

    private static func startService(_ deviceRef: AMDeviceRef) throws -> AMDServiceConnectionRef {
        var conn: AMDServiceConnectionRef?
        var result: Int32 = -1
        for attempt in 0..<3 {
            conn = nil
            result = AMDeviceSecureStartService(deviceRef, serviceName as CFString, nil, &conn)
            if result == AMDAppLEDETECT_SUCCESS, conn != nil { break }
            let transient: Bool = {
                switch UInt32(bitPattern: result) {
                case 0xE8000003, 0xE8000004, 0xE8000005, 0xE800000C, 0xE8000012: return true
                default: return false
                }
            }()
            if !transient { break }
            Thread.sleep(forTimeInterval: 0.3 * Double(attempt + 1))
        }
        guard result == AMDAppLEDETECT_SUCCESS, let c = conn else {
            throw InstallationProxyError.startServiceFailed(result)
        }
        return c
    }

    private static func send(_ dict: [String: Any], over conn: AMDServiceConnectionRef) throws {
        let buffer: Data
        do { buffer = try AMDPlistCodec.frame(dict) } catch { throw InstallationProxyError.badReply }
        try buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < buffer.count {
                let n = AMDServiceConnectionSend(conn, base.advanced(by: sent), buffer.count - sent)
                if n <= 0 { throw InstallationProxyError.sendFailed(errno: errno) }
                sent += Int(n)
            }
        }
    }

    private static func recv(from conn: AMDServiceConnectionRef) throws -> [String: Any] {
        var prefix = [UInt8](repeating: 0, count: 4)
        try prefix.withUnsafeMutableBufferPointer { try readExact(conn, into: $0.baseAddress!, count: 4) }
        guard let bodyLen = AMDPlistCodec.bodyLength(prefix: Data(prefix)), bodyLen > 0, bodyLen < 10_000_000 else {
            throw InstallationProxyError.badReply
        }
        var body = [UInt8](repeating: 0, count: bodyLen)
        try body.withUnsafeMutableBufferPointer { try readExact(conn, into: $0.baseAddress!, count: bodyLen) }
        guard let dict = try? PropertyListSerialization.propertyList(from: Data(body), options: [], format: nil) as? [String: Any] else {
            throw InstallationProxyError.badReply
        }
        return dict
    }

    private static func readExact(_ conn: AMDServiceConnectionRef, into ptr: UnsafeMutableRawPointer, count: Int) throws {
        var read = 0
        while read < count {
            let n = AMDServiceConnectionReceive(conn, ptr.advanced(by: read), count - read)
            if n <= 0 { throw InstallationProxyError.recvFailed(errno: errno) }
            read += Int(n)
        }
    }
}
