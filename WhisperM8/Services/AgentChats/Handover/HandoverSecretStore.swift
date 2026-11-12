import Foundation
import Security

// MARK: - Geheimnis im Schlüsselbund

/// Ergebnis beim Lesen des Einmal-Geheimnisses.
enum HandoverSecretLookup: Equatable {
    case found(String)
    case missing
    /// Zugriff verweigert oder nicht ohne Dialog möglich (anders signierter
    /// Build, etwa Brew ↔ `make dev`). Es gilt der Rückfall per `--resume`.
    case denied(status: Int32)
    /// Der Schlüsselbund hat nicht in der Frist geantwortet.
    case timedOut
}

/// Reicht das Einmal-Geheimnis von der alten an die neue App weiter
/// (Vertrag des Aufbewahrers, `docs/features/agent-chats/neustart-aufbewahrer.md`).
/// Die alte App legt es vor `COMMIT` ab, die neue liest es für `helloTake`
/// beziehungsweise `release` und löscht es danach.
protocol HandoverSecretStoring {
    func store(_ secret: String) -> Bool
    func load() -> HandoverSecretLookup
    func remove()
}

/// Kleine Schicht über die SecItem-Aufrufe; Tests ersetzen sie.
protocol HandoverKeychainBackend {
    func add(service: String, account: String, data: Data) -> OSStatus
    func copyData(service: String, account: String) -> (status: OSStatus, data: Data?)
    func delete(service: String, account: String) -> OSStatus
}

/// Ein Eintrag je Instanz (Dienst je Instanz, Konto aus dem Ordner des
/// Aufbewahrers). Der Zugriff hängt an der Code-Signatur der App, die ihn
/// anlegt: Zwei `make dev`-Builds mit derselben Signatur lesen ihn ohne
/// Dialog; ein anders signierter Build bekommt ihn nicht.
///
/// **Nie ein Dialog, nie ein Hängen:** Gelesen wird ohne Benutzerdialog und
/// mit Frist. Scheitert das, gilt der Rückfall — ein Dialog beim Start nach
/// `make dev` wäre schlimmer als ein `--resume`.
final class HandoverSecretStore: HandoverSecretStoring {
    let service: String
    let account: String
    private let backend: HandoverKeychainBackend
    private let timeout: TimeInterval

    init(
        service: String = HandoverSecretStore.defaultService,
        account: String,
        backend: HandoverKeychainBackend = SecItemHandoverKeychainBackend(),
        timeout: TimeInterval = 2
    ) {
        self.service = service
        self.account = account
        self.backend = backend
        self.timeout = timeout
    }

    static var defaultService: String {
        AppInstance.isTestInstance ? "com.whisperm8.app.test.handover" : "com.whisperm8.app.handover"
    }

    /// Konto-Name aus dem Ordner des Aufbewahrers und der Signatur der App:
    /// eindeutig je Instanz, ohne den Pfad (samt Nutzername) in den
    /// Schlüsselbund zu schreiben. Die Signatur gehört dazu, damit ein anders
    /// signierter Build (Brew ↔ `make dev`) den fremden Eintrag nie anfasst —
    /// schon Löschen oder Überschreiben könnte dort einen Dialog auslösen. Er
    /// findet schlicht keinen und fällt auf `--resume` zurück.
    static func account(for paths: HandoverPaths, signature: String) -> String {
        let instance = AppInstance.stableHash(paths.directory.standardizedFileURL.path)
        let signer = AppInstance.stableHash(signature)
        return "keeper-" + String(UInt64(truncatingIfNeeded: instance), radix: 36)
            + "-" + String(UInt64(truncatingIfNeeded: signer), radix: 36)
    }

    static func live(paths: HandoverPaths = .default) -> HandoverSecretStore {
        HandoverSecretStore(account: account(for: paths, signature: HandoverCodeSignature.designatedRequirement() ?? "unsigned"))
    }

    /// Legt das Geheimnis ab; ein altes Geheimnis derselben Instanz wird
    /// vorher entfernt. `false`, wenn der Schlüsselbund es nicht annimmt —
    /// dann gibt die App nicht ab.
    func store(_ secret: String) -> Bool {
        guard HandoverSecret.isWellFormed(secret) else { return false }
        _ = runWithTimeout { self.backend.delete(service: self.service, account: self.account) }
        let status = runWithTimeout {
            self.backend.add(service: self.service, account: self.account, data: Data(secret.utf8))
        }
        guard let status, status == errSecSuccess else {
            Logger.agentStore.error("handover_secret_store_failed status=\(status ?? -1)")
            return false
        }
        return true
    }

    func load() -> HandoverSecretLookup {
        guard let read = runWithTimeout({ self.backend.copyData(service: self.service, account: self.account) }) else {
            Logger.agentStore.error("handover_secret_load_timeout")
            return .timedOut
        }
        switch read.status {
        case errSecSuccess:
            guard let data = read.data, let text = String(data: data, encoding: .utf8),
                  HandoverSecret.isWellFormed(text) else { return .missing }
            return .found(text)
        case errSecItemNotFound:
            return .missing
        default:
            Logger.agentStore.notice("handover_secret_load_denied status=\(read.status)")
            return .denied(status: read.status)
        }
    }

    /// Nur nach erfolgreichem `load()` aufrufen oder vor dem eigenen
    /// `store()`: Der Eintrag gehört dann sicher dieser Signatur.
    func remove() {
        _ = runWithTimeout { self.backend.delete(service: self.service, account: self.account) }
    }

    /// Führt einen Schlüsselbund-Aufruf mit Frist aus. Läuft er über die
    /// Frist, kommt `nil`; der Aufruf selbst endet irgendwann im Hintergrund.
    private func runWithTimeout<Result>(_ work: @escaping () -> Result) -> Result? {
        let box = ResultBox<Result>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(work())
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.get()
    }
}

private final class ResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Value? { lock.lock(); defer { lock.unlock() }; return value }
}

struct SecItemHandoverKeychainBackend: HandoverKeychainBackend {
    private func baseQuery(_ service: String, _ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func add(service: String, account: String, data: Data) -> OSStatus {
        var query = baseQuery(service, account)
        query[kSecValueData as String] = data
        query[kSecAttrLabel as String] = "WhisperM8 Restart Handover"
        // Nur für diesen Rechner, nie in die iCloud-Synchronisation.
        query[kSecAttrSynchronizable as String] = false
        return SecItemAdd(query as CFDictionary, nil)
    }

    func copyData(service: String, account: String) -> (status: OSStatus, data: Data?) {
        var query = baseQuery(service, account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Kein Dialog: Braucht der Zugriff eine Bestätigung (anders signierter
        // Build), scheitert er mit errSecInteractionNotAllowed.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func delete(service: String, account: String) -> OSStatus {
        var query = baseQuery(service, account)
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        return SecItemDelete(query as CFDictionary)
    }
}

/// Code-Anforderung der laufenden App als Text. Zwei `make dev`-Builds mit
/// dem Zertifikat „WhisperM8 Local Dev“ haben dieselbe, Brew-Build und
/// Dev-Build verschiedene; ein Debug-Build mit Ad-hoc-Signatur hat je Build
/// eine andere (dort gilt immer der Rückfall).
enum HandoverCodeSignature {
    static func designatedRequirement() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }
}
