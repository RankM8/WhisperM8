import Foundation

/// Simple storage for API keys using UserDefaults
enum KeychainManager {
    static func save(key: String, value: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    static func load(key: String) -> String? {
        UserDefaults.standard.string(forKey: key)
    }

    static func delete(key: String) {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
