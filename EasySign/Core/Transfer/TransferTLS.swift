import Foundation
import Network
import Security

/// 构建 WS-over-TLS 的 `NWParameters`:加载本机 `SecIdentity`,并在 TLS 验证回调里
/// 按 `PinMode` 决定是否强校验对端叶证书指纹(已配对),或一律放行(配对中)。
/// 指纹不再经由验证回调回报——每条连接在 `.ready` 后从自己的 TLS metadata 自取。
enum TransferTLS {
    enum PinMode {
        /// 已配对:对端指纹必须等于此值,否则握手失败。
        case requirePinned(fingerprint: String)
        /// 配对中:放行任意对端(应用层 HMAC 负责鉴权)。
        case acceptAny
    }

    static let wsPath = "/ws"
    static let protocolVersion = 1

    static func parameters(identity: SecIdentity, pin: PinMode) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions

        // 本机身份(证书 + 私钥)用于双向 TLS。
        if let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(sec, secIdentity)
        }
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)

        // 双向 TLS:协议依赖每端都拿到对端叶证书指纹(配对/pinning 基础)。
        // 服务端默认不请求客户端证书(peer auth 默认值:client=true,server=false),
        // 必须显式开启,否则服务端永远取不到对端证书 → serverConn.peerFingerprint 恒为 nil。
        sec_protocol_options_set_peer_authentication_required(sec, true)

        // 自签互信:不走系统信任链,改为对端叶证书指纹比对。
        sec_protocol_options_set_verify_block(sec, { _, secTrust, complete in
            switch pin {
            case let .requirePinned(expected):
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                guard let leaf = TransferTLS.leafCertificate(of: trust) else {
                    complete(false)   // 取不到叶证书 → 拒绝(不弱化校验)
                    return
                }
                let der = SecCertificateCopyData(leaf) as Data
                let fp = CertFingerprint.sha256Hex(of: der)
                complete(fp == expected)
            case .acceptAny:
                complete(true)
            }
        }, DispatchQueue(label: "transfer.tls.verify"))

        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true

        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        return params
    }

    /// 取证书链中的叶证书(index 0)。部署目标 13.0 → `SecTrustCopyCertificateChain`(12+)可用。
    private static func leafCertificate(of trust: SecTrust) -> SecCertificate? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else {
            return nil
        }
        return chain.first
    }
}
