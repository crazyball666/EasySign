import Foundation
import CryptoKit

/// 配对码绑证书指纹的 HMAC 认证。规范化 transcript 保证两端一致、跨平台可复现。
enum PairingCrypto {
    /// transcript = 排序后的 ["fp:<a>","fp:<b>","nonce:<x>","nonce:<y>"] 用 "|" 连接。
    static func transcript(fpSelf: String, fpPeer: String,
                           nonceSelf: String, noncePeer: String) -> Data {
        let parts = ["fp:\(fpSelf)", "fp:\(fpPeer)",
                     "nonce:\(nonceSelf)", "nonce:\(noncePeer)"].sorted()
        return Data(parts.joined(separator: "|").utf8)
    }
    static func mac(code: String, fpSelf: String, fpPeer: String,
                    nonceSelf: String, noncePeer: String) -> Data {
        let key = SymmetricKey(data: Data(code.utf8))
        let t = transcript(fpSelf: fpSelf, fpPeer: fpPeer, nonceSelf: nonceSelf, noncePeer: noncePeer)
        return Data(HMAC<SHA256>.authenticationCode(for: t, using: key))
    }
    static func verify(_ tag: Data, code: String, fpSelf: String, fpPeer: String,
                       nonceSelf: String, noncePeer: String) -> Bool {
        let expected = mac(code: code, fpSelf: fpSelf, fpPeer: fpPeer,
                           nonceSelf: nonceSelf, noncePeer: noncePeer)
        guard tag.count == expected.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(tag, expected) { diff |= a ^ b }
        return diff == 0
    }
    static func makeCode() -> String {
        let n = UInt32.random(in: 0...999_999)
        return String(format: "%06u", n)
    }
    static func makeNonceHex() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
