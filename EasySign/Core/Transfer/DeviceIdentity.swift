import Foundation
import Security

/// 自签身份:用系统 openssl 生成 P-256 自签证书 + key,打包 p12,导入 SecIdentity。
enum DeviceIdentity {
    enum IdentityError: Error { case openssl(String); case importFailed(OSStatus); case noIdentity }

    struct Material {
        let p12Data: Data
        let passphrase: String
        let fingerprint: String   // leaf 证书 DER 的 sha256 hex
    }

    struct Loaded {
        let identity: SecIdentity
        let fingerprint: String
    }

    /// 生成一份新身份材料(不落 Keychain)。
    static func generateSelfSigned(commonName: String) throws -> Material {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("easysign-id-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let keyPath = dir.appendingPathComponent("key.pem").path
        let certPath = dir.appendingPathComponent("cert.pem").path
        let p12Path = dir.appendingPathComponent("identity.p12").path
        let pass = PairingCrypto.makeNonceHex()

        // Generate P-256 EC key in traditional (SEC1) format.
        // LibreSSL's -newkey ec produces PKCS#8 which SecPKCS12Import cannot load;
        // ecparam -genkey produces the traditional format the Security framework accepts.
        try runOpenSSL([
            "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", keyPath,
        ])
        try runOpenSSL([
            "req", "-x509", "-key", keyPath, "-new",
            "-out", certPath,
            "-days", "3650",
            "-subj", "/CN=\(commonName)",
        ])
        try runOpenSSL([
            "pkcs12", "-export",
            "-inkey", keyPath, "-in", certPath,
            "-out", p12Path, "-name", "EasySign",
            "-passout", "pass:\(pass)",
        ])

        let p12Data = try Data(contentsOf: URL(fileURLWithPath: p12Path))
        let certDER = try derFromPEM(certPath)
        let fingerprint = CertFingerprint.sha256Hex(of: certDER)
        return Material(p12Data: p12Data, passphrase: pass, fingerprint: fingerprint)
    }

    /// 把 p12 导入成 SecIdentity,并算出指纹。
    static func importIdentity(p12Data: Data, passphrase: String) throws -> Loaded {
        let opts: [String: Any] = [kSecImportExportPassphrase as String: passphrase]
        var items: CFArray?
        let st = SecPKCS12Import(p12Data as CFData, opts as CFDictionary, &items)
        guard st == errSecSuccess else { throw IdentityError.importFailed(st) }
        guard let arr = items as? [[String: Any]],
              let first = arr.first,
              let idAny = first[kSecImportItemIdentity as String]
        else { throw IdentityError.noIdentity }
        let identity = idAny as! SecIdentity

        var certRef: SecCertificate?
        SecIdentityCopyCertificate(identity, &certRef)
        guard let cert = certRef else { throw IdentityError.noIdentity }
        let der = SecCertificateCopyData(cert) as Data
        return Loaded(identity: identity, fingerprint: CertFingerprint.sha256Hex(of: der))
    }

    private static func derFromPEM(_ pemPath: String) throws -> Data {
        let dir = (pemPath as NSString).deletingLastPathComponent
        let derPath = (dir as NSString).appendingPathComponent("cert.der")
        try runOpenSSL(["x509", "-outform", "der", "-in", pemPath, "-out", derPath])
        return try Data(contentsOf: URL(fileURLWithPath: derPath))
    }

    private static func runOpenSSL(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw IdentityError.openssl("openssl \(args.first ?? "") failed: \(msg)")
        }
    }
}
