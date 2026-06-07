import Foundation
import CryptoKit

enum CertFingerprint {
    /// DER 字节的 SHA-256,小写 hex,固定 64 字符。
    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
