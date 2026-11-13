import Foundation

// MARK: - Stellschrauben für den Dauerlauf (nur Test-Instanz)

/// Stellschrauben, mit denen der Dauerlauf (`scripts/handover-soak.sh`) die
/// Rückfall-Wege absichtlich auslöst. Wirken nur in der Test-Instanz
/// (`AppInstance.isTestInstance`); in der Arbeits-App werden sie nie gelesen.
/// Gesetzt per `defaults write com.whisperm8.app.test <Schlüssel> …`.
///
/// Kein Bedienweg und keine Einstellung: deshalb nicht in `PreferenceKeys`.
enum HandoverTestKnobs {
    /// Haltefrist des Aufbewahrers in Sekunden (`-float`), statt 10 Minuten.
    static let holdSecondsKey = "handoverHoldSeconds"
    /// Pause vor jedem `TAKE` in Millisekunden (`-int`), um den Aufbewahrer
    /// mitten in der Übernahme beenden zu können.
    static let takeDelayKey = "handoverTakeDelayMs"
    /// `missing` oder `wrong`: tut so, als fehle das Geheimnis im
    /// Schlüsselbund oder sei falsch.
    static let secretOverrideKey = "handoverSecretOverride"

    static var isActive: Bool { AppInstance.isTestInstance }

    static func holdSeconds(defaults: UserDefaults = .standard, active: Bool = isActive) -> TimeInterval? {
        guard active, defaults.object(forKey: holdSecondsKey) != nil else { return nil }
        let value = defaults.double(forKey: holdSecondsKey)
        return value > 0 ? value : nil
    }

    static func takeDelay(defaults: UserDefaults = .standard, active: Bool = isActive) -> TimeInterval {
        guard active else { return 0 }
        return max(0, Double(defaults.integer(forKey: takeDelayKey)) / 1000)
    }

    /// Ersetzt das Ergebnis des Schlüsselbunds, wenn eine Stellschraube gesetzt ist.
    static func secret(
        _ lookup: HandoverSecretLookup,
        defaults: UserDefaults = .standard,
        active: Bool = isActive
    ) -> HandoverSecretLookup {
        guard active else { return lookup }
        switch defaults.string(forKey: secretOverrideKey) {
        case "missing": return .missing
        case "wrong": return .found(HandoverSecret.make())
        default: return lookup
        }
    }
}
