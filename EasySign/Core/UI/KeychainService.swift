import Foundation
import Security

/// 轻量 Keychain 包装。仅存密码/小字符串。
/// kSecClass=kSecClassGenericPassword，service="com.crazyball.EasySign"。
final class KeychainService {
    static let shared = KeychainService()
    private let service = "com.crazyball.EasySign"

    func set(_ value: String, for key: String) {
        let data = value.data(using: .utf8) ?? Data()
        SecItemDelete(query(for: key) as CFDictionary)
        var add = query(for: key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    func get(_ key: String) -> String? {
        var q = query(for: key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var ref: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &ref)
        guard status == errSecSuccess, let data = ref as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(_ key: String) {
        SecItemDelete(query(for: key) as CFDictionary)
    }

    private func query(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
