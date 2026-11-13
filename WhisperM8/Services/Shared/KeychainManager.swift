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
///
/// Der Cache gilt je App-Lauf: Nach einem neuen Build (neuer cdhash) fragt macOS
/// beim ersten Lesen per Dialog nach. `load` blockiert so lange; vom Main Thread
/// aus stünde die ganze App samt Terminals (5-s-Hänger 13.11.2026). Wer auf dem
/// Main Thread läuft, liest deshalb über `loadOffMain`.
final class KeychainStore: KeychainStoring, @unchecked Sendable {
    private let service: String
    private let backend: KeychainBackend
    private let defaults: UserDefaults
    private var cache: [String: String] = [:]
    /// Zählt Schreib- und Löschvorgänge je Schlüssel. Ein Lesevorgang, der
    /// währenddessen lief, legt seinen alten Wert nicht mehr in den Cache.
    private var generation: [String: Int] = [:]
    /// Laufende Hintergrund-Lesevorgänge: zwei Diktate während eines offenen
    /// Dialogs lösen nur einen Keychain-Zugriff aus.
    private var inFlight: [String: PendingKeychainRead] = [:]
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

        let startGeneration = currentGeneration(for: key)
        let read = backend.copyData(service: service, account: key)
        if read.status == errSecSuccess, let data = read.data {
            let value = String(data: data, encoding: .utf8)
            if let value, !value.isEmpty {
                setCached(value, for: key, ifGeneration: startGeneration)
            }
            return value
        }

        // Migration: alte Versionen hielten den Key in UserDefaults. Die einzige
        // Kopie wird NUR entfernt, wenn der Keychain-Write bestätigt ist
        // (LR-SH-003) — sonst bleibt sie für den nächsten Versuch erhalten.
        // Nur wenn der Eintrag fehlt: Nach einem abgelehnten Dialog stünde sonst
        // eine veraltete Kopie bereit, und `save` überschriebe den echten Key.
        if read.status == errSecItemNotFound,
           let oldValue = defaults.string(forKey: key), !oldValue.isEmpty {
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

    /// Wie `load`, aber der Keychain-Zugriff läuft auf einer Dispatch-Queue statt
    /// auf dem Aufrufer-Thread (und nicht im Swift-Concurrency-Pool, den ein
    /// offener Dialog sonst beliebig lange belegt). Aus dem Cache kommt der Wert
    /// sofort; gleichzeitige Aufrufe teilen sich einen Lesevorgang. Wird der
    /// wartende Task abgebrochen (ESC im Diktat), kehrt der Aufruf sofort mit
    /// `nil` zurück; der Lesevorgang läuft weiter und füllt den Cache.
    func loadOffMain(key: String) async -> String? {
        if let cachedValue = cachedValue(for: key) {
            return cachedValue
        }
        let read: PendingKeychainRead = cacheLock.withLock {
            if let running = inFlight[key] { return running }
            let started = PendingKeychainRead()
            inFlight[key] = started
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let startGeneration = currentGeneration(for: key)
                var value = load(key: key)
                // Während des Lesens gespeichert oder gelöscht: Wartende sollen
                // den neuen Stand bekommen, nicht den alten. Ein zweites `load`
                // trifft den Cache oder liest den geänderten Eintrag.
                if currentGeneration(for: key) != startGeneration {
                    value = load(key: key)
                }
                cacheLock.withLock {
                    if inFlight[key] === started { inFlight[key] = nil }
                }
                started.finish(value)
            }
            return started
        }
        return await read.value()
    }

    /// Nur für Tests: wie viele Aufrufer gerade auf den laufenden Lesevorgang warten.
    func waitingReaders(for key: String) -> Int {
        cacheLock.withLock { inFlight[key]?.waiterCount ?? 0 }
    }

    /// Verwirft nur die Kopie im Speicher (etwa nach 401 vom Anbieter); der
    /// nächste Zugriff liest wieder aus dem Schlüsselbund.
    func forgetCached(key: String) {
        removeCachedValue(for: key)
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

    private func currentGeneration(for key: String) -> Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return generation[key, default: 0]
    }

    private func setCached(_ value: String, for key: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache[key] = value
        generation[key, default: 0] += 1
        // Ein noch laufender Lesevorgang liefert den alten Stand; neue Aufrufer
        // hängen sich nicht mehr daran.
        inFlight[key] = nil
    }

    /// Legt einen gelesenen Wert nur ab, wenn seit dem Lesebeginn niemand
    /// gespeichert oder gelöscht hat.
    private func setCached(_ value: String, for key: String, ifGeneration expected: Int) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard generation[key, default: 0] == expected else { return }
        cache[key] = value
    }

    private func removeCachedValue(for key: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache.removeValue(forKey: key)
        generation[key, default: 0] += 1
        inFlight[key] = nil
    }
}

/// Ein laufender Hintergrund-Lesevorgang mit beliebig vielen Wartenden. Jeder
/// Wartende kann einzeln abbrechen, ohne den Lesevorgang zu beenden.
final class PendingKeychainRead: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false
    private var result: String?
    private var waiters: [UUID: CheckedContinuation<String?, Never>] = [:]
    /// Abbrüche, die vor dem Einhängen der Continuation ankamen.
    private var cancelledEarly: Set<UUID> = []

    var waiterCount: Int { lock.withLock { waiters.count } }

    func value() async -> String? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                lock.lock()
                if isFinished {
                    let value = result
                    lock.unlock()
                    continuation.resume(returning: value)
                } else if cancelledEarly.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else {
                    waiters[id] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            if let continuation = waiters.removeValue(forKey: id) {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                if !isFinished { cancelledEarly.insert(id) }
                lock.unlock()
            }
        }
    }

    func finish(_ value: String?) {
        lock.lock()
        isFinished = true
        result = value
        let pending = Array(waiters.values)
        waiters.removeAll()
        cancelledEarly.removeAll()
        lock.unlock()
        for continuation in pending { continuation.resume(returning: value) }
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
    /// Für Aufrufer auf dem Main Thread: liest abseits davon (siehe `KeychainStore`).
    static func loadOffMain(key: String) async -> String? { await KeychainStore.live.loadOffMain(key: key) }
    static func forgetCached(key: String) { KeychainStore.live.forgetCached(key: key) }
    static func exists(key: String) -> Bool { KeychainStore.live.exists(key: key) }
    static func delete(key: String) { KeychainStore.live.delete(key: key) }
}
