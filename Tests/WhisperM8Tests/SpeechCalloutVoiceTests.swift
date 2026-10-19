import XCTest
@testable import WhisperM8

/// LR-SH-017: Die Stimme folgt der Sprache des Ansagetexts.
@MainActor
final class SpeechCalloutVoiceTests: XCTestCase {
    private let voices: [(String, String, Int)] = [
        ("com.apple.voice.compact.de-DE.Anna", "de-DE", 1),
        ("com.apple.voice.enhanced.en-US.Ava", "en-US", 2),
        ("com.apple.voice.compact.en-GB.Daniel", "en-GB", 1),
    ]

    func testEnglishTextGetsEnglishVoiceGermanGetsGerman() {
        XCTAssertEqual(SystemSpeechCalloutEngine.languageCode(for: "The build finished and all tests passed.", preferred: ["de-DE"]), "en")
        XCTAssertEqual(SystemSpeechCalloutEngine.languageCode(for: "Der Build ist fertig und alle Tests sind grün.", preferred: ["en-US"]), "de")
        XCTAssertEqual(SystemSpeechCalloutEngine.bestVoiceIdentifier(language: "en", voices: voices), "com.apple.voice.enhanced.en-US.Ava")
        XCTAssertEqual(SystemSpeechCalloutEngine.bestVoiceIdentifier(language: "de", voices: voices), "com.apple.voice.compact.de-DE.Anna")
    }

    func testUnclearTextUsesSystemLanguageAndMissingLanguageFallsBackToGerman() {
        XCTAssertEqual(SystemSpeechCalloutEngine.languageCode(for: "ok", preferred: ["en-US"]), "en")
        XCTAssertEqual(SystemSpeechCalloutEngine.bestVoiceIdentifier(language: "fr", voices: voices), "com.apple.voice.compact.de-DE.Anna")
    }
}
