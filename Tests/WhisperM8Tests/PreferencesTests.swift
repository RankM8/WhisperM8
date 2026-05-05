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
            XCTAssertEqual(preferences.defaultOutputModeID, OutputMode.rawID)
            XCTAssertEqual(preferences.lastSelectedOutputModeID, OutputMode.rawID)
            XCTAssertTrue(preferences.fallbackToRawOnProcessingError)
            XCTAssertTrue(preferences.showModePickerInMiniOverlay)
            XCTAssertEqual(preferences.codexPostProcessingModelRaw, CodexPostProcessingModel.defaultModel.rawValue)
            XCTAssertEqual(preferences.codexReasoningEffortRaw, CodexReasoningEffort.defaultEffort.rawValue)
        }
    }

    func testSavesAndLoadsValues() {
        withIsolatedPreferences { preferences in
            preferences.language = "en"
            preferences.isAutoPasteEnabled = false
            preferences.audioDuckingFactor = 0.15
            preferences.selectedAudioDeviceUID = "device-1"
            preferences.defaultOutputModeID = OutputMode.cleanID
            preferences.lastSelectedOutputModeID = OutputMode.emailID
            preferences.fallbackToRawOnProcessingError = false
            preferences.showModePickerInMiniOverlay = false
            preferences.codexPostProcessingModelRaw = CodexPostProcessingModel.gpt52.rawValue
            preferences.codexReasoningEffortRaw = CodexReasoningEffort.high.rawValue

            XCTAssertEqual(preferences.language, "en")
            XCTAssertFalse(preferences.isAutoPasteEnabled)
            XCTAssertEqual(preferences.audioDuckingFactor, 0.15)
            XCTAssertEqual(preferences.selectedAudioDeviceUID, "device-1")
            XCTAssertEqual(preferences.defaultOutputModeID, OutputMode.cleanID)
            XCTAssertEqual(preferences.lastSelectedOutputModeID, OutputMode.emailID)
            XCTAssertFalse(preferences.fallbackToRawOnProcessingError)
            XCTAssertFalse(preferences.showModePickerInMiniOverlay)
            XCTAssertEqual(preferences.codexPostProcessingModelRaw, CodexPostProcessingModel.gpt52.rawValue)
            XCTAssertEqual(preferences.codexReasoningEffortRaw, CodexReasoningEffort.high.rawValue)
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
