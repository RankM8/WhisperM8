import AVFoundation
import Foundation

// MARK: - Testdiktat-Ergebnis

/// Ergebnis des Testdiktats im letzten Onboarding-Schritt.
enum OnboardingTestOutcome: Equatable {
    case notRun
    case succeeded
    case failed(String)

    /// Aus dem `AppState` abgeleitet: ein Fehler schlägt ein altes Ergebnis.
    /// Mit `baseline` zählen nur Ergebnisse, die NACH dem Öffnen des Test-Schritts
    /// entstanden sind (LR-ONB-013) — ein früheres Diktat oder ein alter Fehler
    /// ergäbe sonst „All set“ bzw. einen Fehler ohne Test.
    static func derive(
        lastTranscription: String?,
        lastError: String?,
        baseline: OnboardingTestBaseline? = nil,
        transcriptionRevision: Int = 0,
        errorRevision: Int = 0
    ) -> OnboardingTestOutcome {
        var transcription = lastTranscription
        var error = lastError
        if let baseline {
            if transcriptionRevision <= baseline.transcriptionRevision { transcription = nil }
            if errorRevision <= baseline.errorRevision { error = nil }
        }
        if let error, !error.isEmpty { return .failed(error) }
        if let transcription, !transcription.isEmpty { return .succeeded }
        return .notRun
    }
}

/// Zählerstand beim Öffnen des Test-Schritts.
struct OnboardingTestBaseline: Equatable {
    var transcriptionRevision: Int
    var errorRevision: Int
}

// MARK: - Keychain-Fehler zurücksetzen (LR-ONB-007)

enum OnboardingKeychainFailure {
    /// Neuer Wert von `keychainWriteFailed`, nachdem der Entwurf geändert oder
    /// geleert wurde. Der Fehler gehörte zum letzten Speicherversuch: wer den
    /// Entwurf leert, oder bereits einen gespeicherten Key hat, darf nicht
    /// dauerhaft an „Next“ gehindert bleiben.
    static func afterDraftEdit(current: Bool, draftIsEmpty: Bool, hasSavedKey: Bool) -> Bool {
        if draftIsEmpty || hasSavedKey { return false }
        return current
    }
}

// MARK: - Abschluss-Gate (LR-ONB-013)

/// Pur: darf der Wizard abgeschlossen werden, und darf er „All set" melden?
/// Ersetzt das private `canFinish` der View. „All set" gibt es nur nach einem
/// erfolgreichen Testdiktat; ohne Test oder nach einem Fehler bleibt der Schritt
/// ehrlich (Hinweis „ungetestet" bzw. Fehlertext), Abschließen ist trotzdem
/// möglich, damit kein Fehler (z. B. offline) den Wizard blockiert.
struct OnboardingCompletionGate: Equatable {
    var micGranted: Bool
    var accessibilityGranted: Bool
    var hotkeySet: Bool
    /// Zugang für den gewählten Anbieter ist erfüllt (gespeicherter Key bzw. kein Key nötig).
    var credentialsSatisfied: Bool
    /// Der letzte Schreibversuch in den Schlüsselbund ist gescheitert (LR-ONB-007).
    var keychainWriteFailed: Bool = false
    var testOutcome: OnboardingTestOutcome = .notRun

    var canFinish: Bool {
        micGranted && accessibilityGranted && hotkeySet
            && credentialsSatisfied && !keychainWriteFailed
    }

    /// „All set!" nur nach bestandenem Test.
    var showsSuccess: Bool {
        canFinish && testOutcome == .succeeded
    }

    enum Notice: Equatable {
        case none
        case untested
        case testFailed(String)
    }

    var notice: Notice {
        switch testOutcome {
        case .succeeded: return .none
        case .notRun: return .untested
        case .failed(let message): return .testFailed(message)
        }
    }
}

// MARK: - Schrittfolge (LR-ONB-003, LR-DIK-024)

/// Ein logischer Onboarding-Schritt. Die konkrete Reihenfolge ergibt sich profilabhängig
/// (der Codex-Schritt entfällt für reine Diktat-Profile).
enum OnboardingStep: Equatable {
    case welcome
    case profile
    case permissions
    case hotkey
    case apiKey
    case language
    case claudeCLI
    case codex
    case test
}

enum OnboardingStepPlanner {
    /// Profilabhängige Schrittfolge. Der Claude-Schritt (Installation + Login)
    /// erscheint nur im Full-Profil — Diktat-Profile bekommen keine Agent-Abhängigkeit.
    static func steps(for profile: AppUsageProfile) -> [OnboardingStep] {
        var result: [OnboardingStep] = [.welcome, .profile, .permissions, .hotkey, .apiKey, .language]
        if profile.wantsAgentChats {
            result.append(.claudeCLI)
        }
        if profile.wantsCodexEnrichment {
            result.append(.codex)
        }
        result.append(.test)
        return result
    }
}

// MARK: - Mikrofon (LR-ONB-004)

/// Pur: Was tut der Mikrofon-Button im Wizard? Bei verweigertem Zugriff zeigt
/// `requestAccess` nie wieder einen Dialog — dann gehört der Nutzer in die
/// Systemeinstellungen (gleiche Regel wie `PermissionSettingsModel`).
enum MicrophoneOnboardingAction: Equatable {
    case request
    case openSystemSettings

    static func decide(status: AVAuthorizationStatus) -> MicrophoneOnboardingAction {
        switch status {
        case .notDetermined: return .request
        case .authorized, .denied, .restricted: return .openSystemSettings
        @unknown default: return .openSystemSettings
        }
    }

    static func buttonTitle(status: AVAuthorizationStatus) -> String {
        decide(status: status) == .request
            ? String(localized: "Grant")
            : String(localized: "Open System Settings")
    }

    /// Erklärt dem Nutzer, warum der Button in die Systemeinstellungen führt.
    static func hint(status: AVAuthorizationStatus) -> String? {
        switch status {
        case .denied:
            return String(localized: "Microphone access was denied. Turn on WhisperM8 under Privacy & Security → Microphone, then come back here.")
        case .restricted:
            return String(localized: "Microphone access is restricted on this Mac (for example by a profile or Screen Time). Ask your administrator or change it in System Settings.")
        default:
            return nil
        }
    }
}

// MARK: - Setup fortsetzen (LR-ONB-005)

/// Pur: Was fehlt nach erteilten Rechten noch zum funktionierenden Diktat?
/// Der Wizard wird dafür NICHT erneut erzwungen (dokumentierter Vorfall), die
/// Menüleiste bietet nur „Setup fortsetzen" an.
enum SetupIncompleteReason: Equatable {
    case permissionsMissing
    case hotkeyMissing
    case credentialsMissing

    static func evaluate(
        micGranted: Bool,
        accessibilityGranted: Bool,
        hotkeySet: Bool,
        hasCredentials: Bool,
        requiresAccessibility: Bool = true
    ) -> SetupIncompleteReason? {
        // Bedienungshilfen braucht nur das automatische Einfügen; ohne Auto-Paste
        // landet der Text in der Zwischenablage und nichts fehlt.
        if !micGranted || (requiresAccessibility && !accessibilityGranted) { return .permissionsMissing }
        if !hotkeySet { return .hotkeyMissing }
        if !hasCredentials { return .credentialsMissing }
        return nil
    }

    var message: String {
        switch self {
        case .permissionsMissing:
            return String(localized: "Setup incomplete: permissions missing")
        case .hotkeyMissing:
            return String(localized: "Setup incomplete: no hotkey")
        case .credentialsMissing:
            return String(localized: "Setup incomplete: no API key")
        }
    }
}

/// Kurzer Zwischenspeicher für die Setup-Prüfung der Menüleiste: Der Body wird
/// bei jeder Zustandsänderung neu gebaut, die Prüfung selbst fragt aber
/// Mikrofon, Bedienungshilfen und Schlüsselbund ab. Gültigkeit in Sekunden.
final class SetupIncompleteProbeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (at: Date, reason: SetupIncompleteReason?)?
    private let ttl: TimeInterval
    private let now: () -> Date

    init(ttl: TimeInterval = 5, now: @escaping () -> Date = Date.init) {
        self.ttl = ttl
        self.now = now
    }

    func reason(compute: () -> SetupIncompleteReason?) -> SetupIncompleteReason? {
        lock.lock()
        if let stored, now().timeIntervalSince(stored.at) < ttl {
            let value = stored.reason
            lock.unlock()
            return value
        }
        lock.unlock()
        let value = compute()
        lock.lock()
        stored = (now(), value)
        lock.unlock()
        return value
    }

    func invalidate() {
        lock.lock()
        stored = nil
        lock.unlock()
    }
}

// MARK: - API-Key-Entwurf (LR-ONB-006, LR-ONB-007)

/// Hält einen getippten Key ausschließlich als Entwurf. Gespeichert wird nur auf
/// ausdrückliches `commit()`; Tippen, Leeren oder Provider-Wechsel berühren einen
/// bereits gespeicherten Key nie. Ein gescheiterter Write lässt `hasSavedKey`
/// unverändert und erhält den Entwurf für einen neuen Versuch.
@MainActor
@Observable
final class APIKeyDraftModel {
    var draft = ""
    private(set) var hasSavedKey: Bool
    private(set) var saveError: String?

    private let keychainKey: String
    private let store: KeychainStoring

    init(keychainKey: String, store: KeychainStoring = KeychainStore.live) {
        self.keychainKey = keychainKey
        self.store = store
        self.hasSavedKey = store.exists(key: keychainKey)
    }

    var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canCommit: Bool { !trimmedDraft.isEmpty }

    @discardableResult
    func commit() -> Bool {
        let value = trimmedDraft
        guard !value.isEmpty else { return false }
        switch store.save(key: keychainKey, value: value) {
        case .saved:
            hasSavedKey = true
            saveError = nil
            draft = ""
            return true
        case .failed:
            saveError = String(localized: "Couldn't save the key to the macOS Keychain. Unlock your Keychain and try again.")
            return false
        }
    }

    func remove() {
        store.delete(key: keychainKey)
        hasSavedKey = false
        saveError = nil
        draft = ""
    }
}
