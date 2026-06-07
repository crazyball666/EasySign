import Foundation
import Security

/// 持久化设备身份(证书 DER + 私钥 x963,各自 base64 → Keychain 密码条目)与稳定 deviceId(UserDefaults)。
/// 首次惰性生成;旧版 p12 格式自动迁移(保留指纹,已配对关系不变)。
final class DeviceIdentityStore {
    private let keychain = KeychainService.shared
    private let defaults = UserDefaults.standard
    private let certKey = "transfer.identity.cert"     // 证书 DER base64
    private let privKeyKey = "transfer.identity.key"   // 私钥 x963 base64
    private let legacyP12Key = "transfer.identity.p12" // 旧格式(迁移后删除)
    private let legacyPassKey = "transfer.identity.pass"
    private let deviceIdKey = "transfer.deviceId"
    private let deviceNameKey = "transfer.deviceName"

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
        // 1) 新格式
        if let certB64 = keychain.get(certKey), let keyB64 = keychain.get(privKeyKey),
           let certDER = Data(base64Encoded: certB64), let keyX963 = Data(base64Encoded: keyB64) {
            return try DeviceIdentity.importIdentity(certDER: certDER, keyX963: keyX963)
        }
        // 2) 旧 p12 格式 → 迁移(保留指纹);失败则当作无身份,走重新生成(需重新配对一次)
        if let p12b64 = keychain.get(legacyP12Key), let pass = keychain.get(legacyPassKey),
           let p12 = Data(base64Encoded: p12b64) {
            if let mat = DeviceIdentity.migrateLegacyP12(p12Data: p12, passphrase: pass) {
                save(mat)
                removeLegacy()
                return try DeviceIdentity.importIdentity(certDER: mat.certDER, keyX963: mat.keyX963)
            }
            removeLegacy()
        }
        // 3) 首次生成
        let mat = try DeviceIdentity.generateSelfSigned(commonName: "EasySign-\(deviceId)")
        save(mat)
        return try DeviceIdentity.importIdentity(certDER: mat.certDER, keyX963: mat.keyX963)
    }

    private func save(_ mat: DeviceIdentity.Material) {
        keychain.set(mat.certDER.base64EncodedString(), for: certKey)
        keychain.set(mat.keyX963.base64EncodedString(), for: privKeyKey)
    }

    private func removeLegacy() {
        keychain.delete(legacyP12Key)
        keychain.delete(legacyPassKey)
    }
}
