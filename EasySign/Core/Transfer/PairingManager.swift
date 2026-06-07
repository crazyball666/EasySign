import Foundation

/// 配对握手编排。一次会话绑定一条连接。
/// 流程(双方对称):各发 hello + pairOffer(nonce);收齐 nonce 后各发 pairProof(mac);
/// 收到对端 proof 后校验;通过 → success。
final class PairingManager {
    enum Outcome { case success(PairedPeer); case failed(String) }

    private let code: String
    private let selfFingerprint: String
    private let selfDeviceId: String
    private let selfName: String
    private var peerFingerprint: String
    private var selfNonce = PairingCrypto.makeNonceHex()
    private var peerNonce: String?
    private var peerDeviceId: String?
    private var peerName: String?

    var send: ((WireMessage) -> Void)?
    var onOutcome: ((Outcome) -> Void)?

    init(code: String, selfFingerprint: String, selfDeviceId: String, selfName: String,
         peerFingerprint: String) {
        self.code = code
        self.selfFingerprint = selfFingerprint
        self.selfDeviceId = selfDeviceId
        self.selfName = selfName
        self.peerFingerprint = peerFingerprint
    }

    func begin() {
        send?(.hello(deviceId: selfDeviceId, name: selfName, version: TransferTLS.protocolVersion))
        send?(.pairOffer(nonce: selfNonce))
    }

    func handle(_ msg: WireMessage) {
        switch msg {
        case let .hello(deviceId, name, _):
            peerDeviceId = deviceId; peerName = name
        case let .pairOffer(nonce):
            peerNonce = nonce
            maybeSendProof()
        case let .pairProof(mac):
            verifyPeerProof(mac)
        default:
            break
        }
    }

    private func maybeSendProof() {
        guard let peerNonce else { return }
        let mac = PairingCrypto.mac(code: code, fpSelf: selfFingerprint, fpPeer: peerFingerprint,
                                    nonceSelf: selfNonce, noncePeer: peerNonce)
        send?(.pairProof(mac: mac.map { String(format: "%02x", $0) }.joined()))
    }

    private func verifyPeerProof(_ macHex: String) {
        guard let peerNonce, let mac = Data(hex: macHex) else {
            return finish(.failed("证明格式错误"))
        }
        let ok = PairingCrypto.verify(mac, code: code,
                                      fpSelf: selfFingerprint, fpPeer: peerFingerprint,
                                      nonceSelf: selfNonce, noncePeer: peerNonce)
        if ok {
            let peer = PairedPeer(deviceId: peerDeviceId ?? "unknown",
                                  name: peerName ?? "对方设备",
                                  fingerprint: peerFingerprint)
            send?(.pairResult(ok: true))
            finish(.success(peer))
        } else {
            send?(.pairResult(ok: false))
            finish(.failed("配对码不匹配(可能输错或存在中间人)"))
        }
    }

    private func finish(_ o: Outcome) {
        guard onOutcome != nil else { return }
        let cb = onOutcome; onOutcome = nil
        cb?(o)
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var d = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            d.append(b); idx = next
        }
        self = d
    }
}
