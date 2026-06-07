import Foundation
import Security

/// 持久化设备身份(p12 base64 + 口令 → Keychain)与稳定 deviceId(UserDefaults)。首次惰性生成。
final class DeviceIdentityStore {
    private let keychain = KeychainService.shared
    private let defaults = UserDefaults.standard
    private let p12Key = "transfer.identity.p12"
    private let passKey = "transfer.identity.pass"
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
        if let p12b64 = keychain.get(p12Key), let pass = keychain.get(passKey),
           let p12 = Data(base64Encoded: p12b64) {
            return try DeviceIdentity.importIdentity(p12Data: p12, passphrase: pass)
        }
        let mat = try DeviceIdentity.generateSelfSigned(commonName: "EasySign-\(deviceId)")
        keychain.set(mat.p12Data.base64EncodedString(), for: p12Key)
        keychain.set(mat.passphrase, for: passKey)
        return try DeviceIdentity.importIdentity(p12Data: mat.p12Data, passphrase: mat.passphrase)
    }
}
