import Foundation
import Network

/// 向指定 host:port 发起 WS over TLS 连接。
final class TransferClient {
    private let queue = DispatchQueue(label: "transfer.client")
    private let identity: () throws -> SecIdentity

    init(identity: @escaping () throws -> SecIdentity) {
        self.identity = identity
    }

    /// pin: 已配对用 `.requirePinned`;配对用 `.acceptAny`。
    /// 返回的连接其 `peerFingerprint` 会在 `.ready` 后由连接自身从 TLS metadata 读取写入。
    func connect(host: String, port: UInt16, pin: TransferTLS.PinMode) throws -> TransferConnection {
        let id = try identity()
        // pin 直接透传,无需捕获 conn 的闭包(避免保留环泄漏);指纹由连接自取。
        let params = TransferTLS.parameters(identity: id, pin: pin)
        // WebSocket 客户端必须用 URL endpoint:Network.framework 据此构造合法的
        // HTTP Upgrade 请求(path + Host)。用 hostPort 时这些头缺失 → 服务端中止握手
        // (POSIX 53 / ECONNABORTED)。TLS 已由显式 NWParameters 提供,故用 ws:// 方案,
        // 避免框架因 wss:// 再叠一层 TLS。IPv6 字面量需加方括号。
        let hostForURL = host.contains(":") ? "[\(host)]" : host
        guard let url = URL(string: "ws://\(hostForURL):\(port)\(TransferTLS.wsPath)") else {
            throw NWError.posix(.EINVAL)
        }
        let nw = NWConnection(to: .url(url), using: params)
        let c = TransferConnection(nw, queue: queue)
        c.start()
        return c
    }

    /// 直连 Bonjour 发现出的 endpoint。pin 语义同上(配对用 `.acceptAny`,已配对用 `.requirePinned`)。
    /// 走 endpoint 时由 Network.framework 自行解析 Bonjour service 的 host/port,
    /// WebSocket Upgrade 所需的 Host/path 由 ws options 默认补全。
    func connect(endpoint: NWEndpoint, pin: TransferTLS.PinMode) throws -> TransferConnection {
        let id = try identity()
        let params = TransferTLS.parameters(identity: id, pin: pin)
        let nw = NWConnection(to: endpoint, using: params)
        let c = TransferConnection(nw, queue: queue)
        c.start()
        return c
    }
}
