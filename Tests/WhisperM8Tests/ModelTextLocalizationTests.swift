@testable import WhisperM8
import XCTest

/// LR-ONB-011: Nutzersichtbare Texte aus Models (Provider, Modelle, Profile,
/// GPT-Kontextprofil) sind englisch und stehen als Schlüssel im Katalog. In
/// der Testumgebung liefert `String(localized:)` den Quelltext (das Bundle
/// hat keinen kompilierten Katalog), also prüft dieser Test die englische
/// Basis plus Katalogeintrag.
final class ModelTextLocalizationTests: XCTestCase {
    private static var catalogKeys: Set<String> {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WhisperM8/Localization/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = json["strings"] as? [String: Any] else { return [] }
        return Set(strings.keys)
    }

    private static let germanMarkers = ["ä", "ö", "ü", "Ä", "Ö", "Ü", "ß", " bei ", "Qualität", "Abo", "Erweitert", "Bewährt", "Schneller", "Interne", "enthalten"]

    private var texts: [String] {
        var result: [String] = []
        for provider in TranscriptionProvider.allCases {
            result += [provider.displayName, provider.priceInfo]
            if let badge = provider.recommendationBadge { result.append(badge) }
            if let hint = provider.recommendationHint { result.append(hint) }
        }
        for model in TranscriptionModel.allCases {
            result += [model.displayName, model.description]
        }
        for profile in AppUsageProfile.allCases {
            result += [profile.displayName, profile.summary]
        }
        for context in ClaudeGPTContextProfile.allCases {
            result.append(context.title)
        }
        return result
    }

    func testModelTextsAreEnglish() {
        for text in texts {
            for marker in Self.germanMarkers where text.contains(marker) {
                XCTFail("„\(text)“ enthält deutschen Marker „\(marker)“")
            }
        }
    }

    func testModelTextsAreCatalogKeys() {
        let keys = Self.catalogKeys
        XCTAssertFalse(keys.isEmpty)
        // Eigennamen ohne Übersetzung brauchen keinen Eintrag.
        let properNames: Set<String> = ["OpenAI", "Groq", "Whisper", "GPT-4o Transcribe", "Whisper Large v3", "Whisper Large v3 Turbo", "$0.006/min", "$0.002/min"]
        for text in texts where !properNames.contains(text) && !keys.contains(text) {
            XCTFail("„\(text)“ fehlt im String-Katalog")
        }
    }
}
