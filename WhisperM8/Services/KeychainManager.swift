import Foundation
import Security

/// Secure storage for API keys using macOS Keychain
enum KeychainManager {
    private static let service = "com.whisperm8.app"

    static func save(key: String, value: String) {
        // Delete existing item first
        delete(key: key)

        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            Logger.permission.error("Keychain save failed: \(status)")
        }
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }

        // Migration: Check UserDefaults for old keys
        if let oldValue = UserDefaults.standard.string(forKey: key), !oldValue.isEmpty {
            Logger.permission.info("Migrating API key from UserDefaults to Keychain")
            save(key: key, value: oldValue)
            UserDefaults.standard.removeObject(forKey: key)
            return oldValue
        }

        return nil
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }
}
