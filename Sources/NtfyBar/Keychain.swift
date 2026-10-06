import Foundation
import Security
import KeychainShim

/// Generic-password storage for the server password and access token.
enum Keychain {
    private static let service = "com.kudcrafts.ntfy-bar"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String?, for account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var attrs = base
        attrs[kSecValueData as String] = Data(value.utf8)
        attrs[kSecAttrLabel as String] = "ntfy-bar (\(account))"
        if let access = NBCreateOpenAccess("ntfy-bar" as CFString) {
            attrs[kSecAttrAccess as String] = access
        }
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess { Log.write("keychain: add \(account) failed (\(status))") }
        return status == errSecSuccess
    }
}
