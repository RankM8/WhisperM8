import Foundation
import Security

/// Ausgang eines Keychain-Zugriffs, den der Aufrufer auswerten muss
/// (LR-ONB-007/LR-SH-003: früher war `save` ein `Void` — ein gescheiterter
/// Write sah für die UI wie ein vorhandener Zugang aus).
enum KeychainSaveResult: Equatable {
    case saved
    case failed(status: Int32)

    var succeeded: Bool { self == .saved }
}

/// Dünne Schicht über die SecItem-Aufrufe. Produktion: `SecItemKeychainBackend`;
/// Tests ersetzen sie durch einen Fake mit frei wählbarem OSStatus.
protocol KeychainBackend {
    func update(service: String, account: String, data: Data) -> OSStatus
    func add(service: String, account: String, data: Data) -> OSStatus
    func copyData(service: String, account: String) -> (status: OSStatus, data: Data?)
    func probe(service: String, account: String) -> OSStatus
    func delete(service: String, account: String) -> OSStatus
}

struct SecItemKeychainBackend: KeychainBackend {
    private func baseQuery(_ service: String, _ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func update(service: String, account: String, data: Data) -> OSStatus {
        SecItemUpdate(
            baseQuery(service, account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
    }

    func add(service: String, account: String, data: Data) -> OSStatus {
        var query = baseQuery(service, account)
        query[kSecValueData as String] = data
        return SecItemAdd(query as CFDictionary, nil)
    }

    func copyData(service: String, account: String) -> (status: OSStatus, data: Data?) {
        var query = baseQuery(service, account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func probe(service: String, account: String) -> OSStatus {
        var query = baseQuery(service, account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result)
    }

    func delete(service: String, account: String) -> OSStatus {
        SecItemDelete(baseQuery(service, account) as CFDictionary)
    }
}

/// Vertrag für alles, was Keys speichert — Onboarding/Settings bekommen ihn
/// per Closure/Protokoll injiziert, damit Fehlerpfade testbar sind.
protocol KeychainStoring {
    @discardableResult func save(key: String, value: String) -> KeychainSaveResult
    func load(key: String) -> String?
    func exists(key: String) -> Bool
    func delete(key: String)
}

/// Keychain-Speicher mit injizierbarem Backend, Defaults und Cache.
final class KeychainStore: KeychainStoring {
    private let service: String
    private let backend: KeychainBackend
    private let defaults: UserDefaults
    private var cache: [String: String] = [:]
    private let cacheLock = NSLock()

    init(service: String, backend: KeychainBackend, defaults: UserDefaults = .standard) {
        self.service = service
        self.backend = backend
        self.defaults = defaults
    }

    /// Produktiv-Instanz. Test-Instanz mit eigenem Dienst: kein Zugriffsdialog auf
    /// die Produktiv-Schlüssel, nichts überschrieben.
    static let live = KeychainStore(
        service: AppInstance.isTestInstance ? "com.whisperm8.app.test" : "com.whisperm8.app",
        backend: SecItemKeychainBackend()
    )

    @discardableResult
    func save(key: String, value: String) -> KeychainSaveResult {
        guard let data = value.data(using: .utf8) else { return .failed(status: errSecParam) }

        var status = backend.update(service: service, account: key, data: data)
        if status == errSecItemNotFound {
            status = backend.add(service: service, account: key, data: data)
        }

        if status == errSecSuccess {
            setCached(value, for: key)
            return .saved
        }
        Logger.permission.error("Keychain save failed for \(key): \(status)")
        return .failed(status: status)
    }

    func load(key: String) -> String? {
        if let cachedValue = cachedValue(for: key) {
            return cachedValue
        }

        let read = backend.copyData(service: service, account: key)
        if read.status == errSecSuccess, let data = read.data {
            let value = String(data: data, encoding: .utf8)
            if let value, !value.isEmpty {
                setCached(value, for: key)
            }
            return value
        }

        // Migration: alte Versionen hielten den Key in UserDefaults. Die einzige
        // Kopie wird NUR entfernt, wenn der Keychain-Write bestätigt ist
        // (LR-SH-003) — sonst bleibt sie für den nächsten Versuch erhalten.
        if let oldValue = defaults.string(forKey: key), !oldValue.isEmpty {
            Logger.permission.info("Migrating API key from UserDefaults to Keychain")
            if save(key: key, value: oldValue).succeeded {
                defaults.removeObject(forKey: key)
            } else {
                Logger.permission.error("Keychain migration kept legacy copy for \(key)")
            }
            return oldValue
        }

        return nil
    }

    func exists(key: String) -> Bool {
        if cachedValue(for: key)?.isEmpty == false {
            return true
        }

        let status = backend.probe(service: service, account: key)
        if status == errSecSuccess {
            return true
        }
        // Gesperrter Schlüsselbund: der Eintrag ist (vermutlich) da, nur nicht lesbar.
        if status == errSecInteractionNotAllowed {
            return true
        }
        return defaults.string(forKey: key)?.isEmpty == false
    }

    func delete(key: String) {
        _ = backend.delete(service: service, account: key)
        // Legacy-Migration: ohne dieses Aufräumen meldet exists() den Key nach dem
        // Löschen weiter als vorhanden (Review-Befund K1, Flotte 2026-07-06).
        defaults.removeObject(forKey: key)
        removeCachedValue(for: key)
    }

    private func cachedValue(for key: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    private func setCached(_ value: String, for key: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache[key] = value
    }

    private func removeCachedValue(for key: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache.removeValue(forKey: key)
    }
}

/// Secure storage for API keys using macOS Keychain (statische Fassade über
/// `KeychainStore.live`, damit bestehende Aufrufer unverändert bleiben).
enum KeychainManager {
    @discardableResult
    static func save(key: String, value: String) -> KeychainSaveResult {
        KeychainStore.live.save(key: key, value: value)
    }

    static func load(key: String) -> String? { KeychainStore.live.load(key: key) }
    static func exists(key: String) -> Bool { KeychainStore.live.exists(key: key) }
    static func delete(key: String) { KeychainStore.live.delete(key: key) }
}
