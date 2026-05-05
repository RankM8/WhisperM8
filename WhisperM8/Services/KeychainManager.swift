import Foundation
import Security

/// Secure storage for API keys using macOS Keychain
enum KeychainManager {
    private static let service = "com.whisperm8.app"
    private static var cache: [String: String] = [:]
    private static let cacheLock = NSLock()

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        if status == errSecSuccess {
            setCached(value, for: key)
        } else {
            Logger.permission.error("Keychain save failed for \(key): \(status)")
        }
    }

    static func load(key: String) -> String? {
        if let cachedValue = cachedValue(for: key) {
            return cachedValue
        }

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
            let value = String(data: data, encoding: .utf8)
            if let value, !value.isEmpty {
                setCached(value, for: key)
            }
            return value
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

    static func exists(key: String) -> Bool {
        if cachedValue(for: key)?.isEmpty == false {
            return true
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess {
            return true
        }

        if status == errSecInteractionNotAllowed {
            return true
        }

        return UserDefaults.standard.string(forKey: key)?.isEmpty == false
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
        removeCachedValue(for: key)
    }

    private static func cachedValue(for key: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    private static func setCached(_ value: String, for key: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache[key] = value
    }

    private static func removeCachedValue(for key: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache.removeValue(forKey: key)
    }
}
