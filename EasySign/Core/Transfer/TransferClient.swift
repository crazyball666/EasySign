import Foundation
import Network

/// 向指定 host:port 发起 WS over TLS 连接。
final class TransferClient {
    private let queue = DispatchQueue(label: "transfer.client")
    private let identity: () throws -> SecIdentity

    init(identity: @escaping () throws -> SecIdentity) {
        self.identity = identity
    }

    /// pin: 已配对用 `.requirePinned`;配对用 `.capture`。
    /// 返回的连接其 `peerFingerprint` 会在握手时被 capture 回调写入(capture 模式)。
    func connect(host: String, port: UInt16, pin: TransferTLS.PinMode) throws -> TransferConnection {
        let id = try identity()
        // 客户端侧 params 是 per-connection 独立创建的,所以可以把 capture 的指纹
        // 精确写回本连接,不存在 server 侧的共享槽位竞争。
        var conn: TransferConnection?
        let effectivePin: TransferTLS.PinMode
        switch pin {
        case .requirePinned:
            effectivePin = pin
        case let .capture(userCb):
            effectivePin = .capture { fp in
                conn?.peerFingerprint = fp
                userCb(fp)
            }
        }
        let params = TransferTLS.parameters(identity: id, pin: effectivePin)
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host),
                                           port: NWEndpoint.Port(rawValue: port)!)
        let nw = NWConnection(to: endpoint, using: params)
        let c = TransferConnection(nw, queue: queue)
        conn = c
        c.start()
        return c
    }
}
