import Foundation
import XCTest
@testable import WhisperM8

final class PreferencesTests: XCTestCase {
    func testDefaultsUseExpectedValues() {
        withIsolatedPreferences { preferences in
            XCTAssertEqual(preferences.language, "de")
            XCTAssertTrue(preferences.isAutoPasteEnabled)
            XCTAssertTrue(preferences.isAudioDuckingEnabled)
            XCTAssertEqual(preferences.audioDuckingFactor, 0.2)
            XCTAssertEqual(preferences.overlayStyleRaw, OverlayStyle.full.rawValue)
            XCTAssertFalse(preferences.onboardingCompleted)
        }
    }

    func testSavesAndLoadsValues() {
        withIsolatedPreferences { preferences in
            preferences.language = "en"
            preferences.isAutoPasteEnabled = false
            preferences.audioDuckingFactor = 0.15
            preferences.selectedAudioDeviceUID = "device-1"

            XCTAssertEqual(preferences.language, "en")
            XCTAssertFalse(preferences.isAutoPasteEnabled)
            XCTAssertEqual(preferences.audioDuckingFactor, 0.15)
            XCTAssertEqual(preferences.selectedAudioDeviceUID, "device-1")
        }
    }

    func testMigratesLegacyOpenAIWhisperProvider() {
        withIsolatedPreferences { preferences in
            preferences.selectedProviderRaw = "openai_whisper"
            preferences.selectedModelRaw = nil

            TranscriptionSettings.migrateIfNeeded()

            XCTAssertEqual(TranscriptionSettings.loadProvider(), .openai)
            XCTAssertEqual(TranscriptionSettings.loadModel(), .openai_whisper)
        }
    }

    func testSaveModelAlsoUpdatesProvider() {
        withIsolatedPreferences { _ in
            TranscriptionSettings.saveModel(.groq_whisper_v3_turbo)

            XCTAssertEqual(TranscriptionSettings.loadProvider(), .groq)
            XCTAssertEqual(TranscriptionSettings.loadModel(), .groq_whisper_v3_turbo)
        }
    }
}

private func withIsolatedPreferences(_ body: (AppPreferences) -> Void) {
    let suiteName = "WhisperM8Tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let original = AppPreferences.shared
    let preferences = AppPreferences(defaults: defaults)
    AppPreferences.shared = preferences
    defer {
        AppPreferences.shared = original
        defaults.removePersistentDomain(forName: suiteName)
    }

    body(preferences)
}
