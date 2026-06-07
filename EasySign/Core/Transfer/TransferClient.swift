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
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host),
                                           port: NWEndpoint.Port(rawValue: port)!)
        let nw = NWConnection(to: endpoint, using: params)
        let c = TransferConnection(nw, queue: queue)
        c.start()
        return c
    }
}
