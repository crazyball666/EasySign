import Foundation
import CryptoKit
import Security

/// 自签身份:CryptoKit 生成 P-256 私钥,系统 openssl 出自签证书(DER),
/// 用公开 API SecIdentityCreate(macOS 10.12+)在内存合成 SecIdentity —— 全程不碰登录钥匙串。
/// (历史方案 SecPKCS12Import 会把身份作为副作用导入登录钥匙串,污染一堆 EasySign-* 证书。)
enum DeviceIdentity {
    enum IdentityError: Error { case openssl(String); case importFailed(OSStatus); case noIdentity }

    struct Material {
        let certDER: Data         // 自签 leaf 证书(DER)
        let keyX963: Data         // P-256 私钥(ANSI X9.63:04‖X‖Y‖K)
        let fingerprint: String   // 证书 DER 的 sha256 hex
    }

    struct Loaded {
        let identity: SecIdentity
        let fingerprint: String
    }

    /// 生成一份新身份材料(纯内存 + 临时文件,不落 Keychain)。
    static func generateSelfSigned(commonName: String) throws -> Material {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("easysign-id-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // CryptoKit 生成 P-256;PEM 喂给 openssl 出证书,x963 原始字节供 SecKeyCreateWithData。
        let privateKey = P256.Signing.PrivateKey()
        let keyPath = dir.appendingPathComponent("key.pem")
        try privateKey.pemRepresentation.write(to: keyPath, atomically: true, encoding: .utf8)

        let certPath = dir.appendingPathComponent("cert.der").path
        // 注意 -new:LibreSSL 的 req -x509 不带 -new 会去读已有 CSR("Expecting: CERTIFICATE REQUEST")。
        try runOpenSSL([
            "req", "-new", "-x509", "-key", keyPath.path,
            "-outform", "der", "-out", certPath,
            "-days", "3650",
            "-subj", "/CN=\(commonName)",
        ])

        let certDER = try Data(contentsOf: URL(fileURLWithPath: certPath))
        return Material(certDER: certDER,
                        keyX963: privateKey.x963Representation,
                        fingerprint: CertFingerprint.sha256Hex(of: certDER))
    }

    /// 证书 DER + 私钥 x963 → 内存 SecIdentity(SecIdentityCreate,公开 API,零钥匙串)。
    static func importIdentity(certDER: Data, keyX963: Data) throws -> Loaded {
        guard let cert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw IdentityError.noIdentity
        }
        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var kerr: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(keyX963 as CFData, keyAttrs as CFDictionary, &kerr) else {
            throw IdentityError.noIdentity
        }
        guard let identity = SecIdentityCreate(kCFAllocatorDefault, cert, key) else {
            throw IdentityError.noIdentity   // 私钥与证书公钥不匹配时返回 nil
        }
        return Loaded(identity: identity, fingerprint: CertFingerprint.sha256Hex(of: certDER))
    }

    /// 迁移旧版 p12 持久化格式 → 新材料(保留证书/指纹,已配对关系不变)。
    /// 仅在首次升级时走一次;失败则调用方重新生成身份(需重新配对一次)。
    static func migrateLegacyP12(p12Data: Data, passphrase: String) -> Material? {
        var opts: [String: Any] = [kSecImportExportPassphrase as String: passphrase]
        if #available(macOS 15.0, *) {
            opts[kSecImportToMemoryOnly as String] = true   // 迁移这一次也尽量别碰钥匙串
        }
        var items: CFArray?
        guard SecPKCS12Import(p12Data as CFData, opts as CFDictionary, &items) == errSecSuccess,
              let arr = items as? [[String: Any]], let first = arr.first,
              let idAny = first[kSecImportItemIdentity as String]
        else { return nil }
        let identity = idAny as! SecIdentity

        var certRef: SecCertificate?
        var keyRef: SecKey?
        guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess, let cert = certRef,
              SecIdentityCopyPrivateKey(identity, &keyRef) == errSecSuccess, let key = keyRef,
              let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else { return nil }
        let certDER = SecCertificateCopyData(cert) as Data
        return Material(certDER: certDER, keyX963: keyData,
                        fingerprint: CertFingerprint.sha256Hex(of: certDER))
    }

    private static func runOpenSSL(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        // 先排空管道再 wait,避免子进程输出填满缓冲造成死锁(同 TaskCenter 的修复)。
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: errData, encoding: .utf8) ?? ""
            throw IdentityError.openssl("openssl \(args.first ?? "") failed: \(msg)")
        }
    }
}
