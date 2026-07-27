import Foundation

// ==============================================================================
// Auswahl der Erkennungs-Locale.
//
// On-Device-Spracherkennung haengt an heruntergeladenen Modellen, und die sind
// pro REGION verschieden — auf diesem Mac war am 26.07.2026 `de_CH` installiert,
// `de_DE` und `de_AT` nicht. Statt den Menschen zu einem Asset-Download zu
// schicken, nimmt das Voice Gate die beste verfuegbare Variante derselben
// Sprache. Fuer zwei feste Kommandophrasen ist die Regionalvariante
// unerheblich; ein fehlendes Modell waere dagegen ein harter Stopp.
// ==============================================================================

enum VoiceGateLocaleResolver {
    /// Bevorzugte Reihenfolge je Sprache — Standardvariante zuerst.
    static let candidates: [String: [String]] = [
        "de": ["de_DE", "de_CH", "de_AT"],
        "en": ["en_US", "en_GB", "en_AU"]
    ]

    /// Erste Locale, fuer die On-Device-Erkennung wirklich bereitsteht.
    ///
    /// - Parameter isOnDeviceCapable: Faehigkeitspruefung, in Produktion
    ///   `SFSpeechRecognizer(locale:)?.supportsOnDeviceRecognition`. Als Closure,
    ///   damit die Auswahl ohne Speech-Framework testbar bleibt.
    static func resolve(
        preferredLanguage: String,
        isOnDeviceCapable: (Locale) -> Bool
    ) -> Locale? {
        let language = preferredLanguage.lowercased()
        let ordered = candidates[language] ?? ["\(language)_\(language.uppercased())"]

        for identifier in ordered {
            let locale = Locale(identifier: identifier)
            if isOnDeviceCapable(locale) { return locale }
        }
        return nil
    }

    /// Menschenlesbarer Hinweis, wenn nichts passt.
    static func unavailableHint(preferredLanguage: String) -> String {
        let ordered = candidates[preferredLanguage.lowercased()] ?? []
        let list = ordered.joined(separator: ", ")
        return "Keine On-Device-Spracherkennung für \(preferredLanguage) gefunden (geprüft: \(list)). "
            + "In Systemeinstellungen → Tastatur → Diktat die Sprache hinzufügen."
    }
}
