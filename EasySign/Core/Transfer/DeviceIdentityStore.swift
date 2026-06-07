import Foundation

/// 持久化设备身份(证书 DER + 私钥 x963)到 Application Support 文件(权限 0600)与稳定 deviceId(UserDefaults)。
///
/// 为什么用文件而非钥匙串:互传一启动就要读设备身份;本地开发每次编译都是 ad-hoc 签名、
/// 代码签名指纹每次都变,登录钥匙串的 ACL 每次都不认这个"新 app",于是每次启动都弹密码授权。
/// 该身份只是局域网自签 TLS 用的"够用即可"身份(非高价值机密,且互传另有配对码),
/// 故改存普通文件,启动读文件不碰钥匙串 = 不再弹密码。
final class DeviceIdentityStore {
    private let defaults = UserDefaults.standard
    private let deviceIdKey = "transfer.deviceId"
    private let deviceNameKey = "transfer.deviceName"

    private struct Stored: Codable {
        let certDER: Data      // JSON 里自动 base64
        let keyX963: Data
    }

    private var identityURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EasySign/Transfer", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return base.appendingPathComponent("identity.json")
    }

    var deviceId: String {
        if let v = defaults.string(forKey: deviceIdKey) { return v }
        let v = "dev-" + UUID().uuidString.prefix(12)
        defaults.set(v, forKey: deviceIdKey)
        return v
    }

    var deviceName: String {
        get { defaults.string(forKey: deviceNameKey) ?? Host.current().localizedName ?? "Mac" }
        set { defaults.set(newValue, forKey: deviceNameKey) }
    }

    func loadOrCreate() throws -> DeviceIdentity.Loaded {
        // 文件已存在:直接读(启动不碰钥匙串)
        if let stored = readStored() {
            return try DeviceIdentity.importIdentity(certDER: stored.certDER, keyX963: stored.keyX963)
        }
        // 否则首次生成并落盘
        let mat = try DeviceIdentity.generateSelfSigned(commonName: "EasySign-\(deviceId)")
        writeStored(Stored(certDER: mat.certDER, keyX963: mat.keyX963))
        return try DeviceIdentity.importIdentity(certDER: mat.certDER, keyX963: mat.keyX963)
    }

    // MARK: - 文件存储

    private func readStored() -> Stored? {
        guard let data = try? Data(contentsOf: identityURL) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    private func writeStored(_ s: Stored) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: identityURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identityURL.path)
    }
}
