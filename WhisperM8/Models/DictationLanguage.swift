import Foundation

/// Diktiersprache (LR-DIK-024): Standard folgt der Systemsprache; leer = automatische
/// Erkennung (das `language`-Feld wird dann nicht an Whisper geschickt).
enum DictationLanguage {
    /// Von Whisper unterstützte Sprachen (ISO 639-1), eine gängige Auswahl.
    static let supportedCodes: [String] = [
        "de", "en", "fr", "es", "it", "pt", "nl", "pl", "tr", "ru", "uk", "cs",
        "sv", "da", "no", "fi", "el", "hu", "ro", "ja", "ko", "zh", "ar", "hi", "he", "id"
    ]

    /// Auswahlliste inkl. Auto-Erkennung (leer) zuletzt.
    static var pickerCodes: [String] { supportedCodes + [""] }

    /// Pur: erste unterstützte Sprache aus der Systemreihenfolge, sonst Auto (leer).
    static func defaultCode(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        for identifier in preferredLanguages {
            let raw = Locale(identifier: identifier).language.languageCode?.identifier
                ?? String(identifier.prefix(2))
            let code = raw.lowercased()
            let normalized = (code == "nb" || code == "nn") ? "no" : code
            if supportedCodes.contains(normalized) { return normalized }
        }
        return ""
    }

    /// Anzeigename in der Sprache der Oberfläche; leer = Auto-Erkennung.
    static func displayName(for code: String) -> String {
        if code.isEmpty { return String(localized: "Auto-detect") }
        return Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
    }
}
