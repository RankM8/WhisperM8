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
            XCTAssertEqual(preferences.overlayStyleRaw, OverlayStyle.mini.rawValue)
            // Beschlossen 2026-07-06: Erstinstallation startet mit Fast (raw) —
            // gespeicherte Werte bleiben unangetastet (siehe Folge-Asserts).
            XCTAssertEqual(preferences.defaultOutputModeID, OutputMode.rawID)
            XCTAssertEqual(preferences.lastSelectedOutputModeID, OutputMode.rawID)
            XCTAssertTrue(preferences.fallbackToRawOnProcessingError)
            XCTAssertTrue(preferences.showModePickerInMiniOverlay)
            XCTAssertTrue(preferences.isSelectedContextCaptureEnabled)
            XCTAssertTrue(preferences.isVisualContextCaptureEnabled)
            XCTAssertEqual(preferences.maxScreenshotsPerRecording, 20)
            XCTAssertEqual(preferences.maxScreenRecordingDuration, 30)
            XCTAssertFalse(preferences.deleteContextFilesAfterProcessing)
            XCTAssertEqual(preferences.codexPostProcessingModelRaw, CodexPostProcessingModel.defaultModel.rawValue)
            XCTAssertEqual(preferences.codexReasoningEffortRaw, CodexReasoningEffort.defaultEffort.rawValue)
            XCTAssertEqual(preferences.codexServiceTierRaw, CodexServiceTier.defaultTier.rawValue)
            XCTAssertEqual(preferences.codexVisualInputModeRaw, CodexVisualInputMode.defaultMode.rawValue)
            XCTAssertTrue(preferences.isAgentSidebarDragEnabled)
        }
    }

    func testAgentSidebarDragEscapeHatchPersists() {
        withIsolatedPreferences { preferences in
            preferences.isAgentSidebarDragEnabled = false
            XCTAssertFalse(preferences.isAgentSidebarDragEnabled)
        }
    }

    func testMigratesLegacyScreenshotDefaultToTwenty() {
        let suiteName = "WhisperM8Tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(3, forKey: PreferenceKeys.maxScreenshotsPerRecording)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = AppPreferences(defaults: defaults)

        XCTAssertEqual(preferences.maxScreenshotsPerRecording, 20)
    }

    func testClaudeGPTFastModeDefaultsToEnabledAndPersistsDisabled() {
        withIsolatedPreferences { preferences in
            XCTAssertTrue(preferences.claudeGPTFastModeEnabled)
            preferences.claudeGPTFastModeEnabled = false
            XCTAssertFalse(preferences.claudeGPTFastModeEnabled)
        }
    }

    func testClaudeGPTPickerModelDefaultsToEmptyAndPersists() {
        withIsolatedPreferencesAndDefaults { preferences, defaults in
            XCTAssertEqual(preferences.claudeGPTPickerModel, "")

            preferences.claudeGPTPickerModel = "gpt-5.6-luna-fast"

            XCTAssertEqual(
                AppPreferences(defaults: defaults).claudeGPTPickerModel,
                "gpt-5.6-luna-fast"
            )
        }
    }

    func testClaudeGPTAutoCompactWindowClampsAndFallsBack() {
        withIsolatedPreferences { preferences in
            // Unset → getesteter Default (272k).
            XCTAssertEqual(
                preferences.claudeGPTAutoCompactWindow,
                AppPreferences.claudeGPTDefaultAutoCompactWindow
            )
            // Tippfehler wie 2 720 000 wuerden die Kompaktierung faktisch
            // abschalten → Clamp auf die Obergrenze.
            preferences.claudeGPTAutoCompactWindow = 2_720_000
            XCTAssertEqual(
                preferences.claudeGPTAutoCompactWindow,
                AppPreferences.claudeGPTAutoCompactWindowRange.upperBound
            )
            preferences.claudeGPTAutoCompactWindow = 5
            XCTAssertEqual(
                preferences.claudeGPTAutoCompactWindow,
                AppPreferences.claudeGPTAutoCompactWindowRange.lowerBound
            )
            preferences.claudeGPTAutoCompactWindow = 300_000
            XCTAssertEqual(preferences.claudeGPTAutoCompactWindow, 300_000)
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
            preferences.isSelectedContextCaptureEnabled = false
            preferences.isVisualContextCaptureEnabled = false
            preferences.maxScreenshotsPerRecording = 2
            preferences.maxScreenRecordingDuration = 12
            preferences.deleteContextFilesAfterProcessing = false
            preferences.codexPostProcessingModelRaw = CodexPostProcessingModel.gpt52.rawValue
            preferences.codexReasoningEffortRaw = CodexReasoningEffort.high.rawValue
            preferences.codexServiceTierRaw = CodexServiceTier.standard.rawValue
            preferences.codexVisualInputModeRaw = CodexVisualInputMode.video.rawValue

            XCTAssertEqual(preferences.language, "en")
            XCTAssertFalse(preferences.isAutoPasteEnabled)
            XCTAssertEqual(preferences.audioDuckingFactor, 0.15)
            XCTAssertEqual(preferences.selectedAudioDeviceUID, "device-1")
            XCTAssertEqual(preferences.defaultOutputModeID, OutputMode.cleanID)
            XCTAssertEqual(preferences.lastSelectedOutputModeID, OutputMode.emailID)
            XCTAssertFalse(preferences.fallbackToRawOnProcessingError)
            XCTAssertFalse(preferences.showModePickerInMiniOverlay)
            XCTAssertFalse(preferences.isSelectedContextCaptureEnabled)
            XCTAssertFalse(preferences.isVisualContextCaptureEnabled)
            XCTAssertEqual(preferences.maxScreenshotsPerRecording, 2)
            XCTAssertEqual(preferences.maxScreenRecordingDuration, 12)
            XCTAssertFalse(preferences.deleteContextFilesAfterProcessing)
            XCTAssertEqual(preferences.codexPostProcessingModelRaw, CodexPostProcessingModel.gpt52.rawValue)
            XCTAssertEqual(preferences.codexReasoningEffortRaw, CodexReasoningEffort.high.rawValue)
            XCTAssertEqual(preferences.codexServiceTierRaw, CodexServiceTier.standard.rawValue)
            XCTAssertEqual(preferences.codexVisualInputModeRaw, CodexVisualInputMode.video.rawValue)
        }
    }

    func testDefaultAgentLaunchTargetMapsRawValueToProviderAndKind() {
        withIsolatedPreferences { preferences in
            // Default ohne user-set value: "claude" → (claude, nil)
            let defaultTarget = preferences.defaultAgentLaunchTarget
            XCTAssertEqual(defaultTarget.provider, .claude)
            XCTAssertNil(defaultTarget.kind)

            // Codex
            preferences.defaultAgentProviderRaw = "codex"
            XCTAssertEqual(preferences.defaultAgentLaunchTarget.provider, .codex)
            XCTAssertNil(preferences.defaultAgentLaunchTarget.kind)

            // Claude Agents View — neuer 3-Wege Wert
            preferences.defaultAgentProviderRaw = "claude-agents"
            XCTAssertEqual(preferences.defaultAgentLaunchTarget.provider, .claude)
            XCTAssertEqual(preferences.defaultAgentLaunchTarget.kind, .agentView)

            // Unbekannter Wert: konservativ auf Claude chat zurueckfallen.
            preferences.defaultAgentProviderRaw = "garbage-string"
            XCTAssertEqual(preferences.defaultAgentLaunchTarget.provider, .claude)
            XCTAssertNil(preferences.defaultAgentLaunchTarget.kind)
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

    func testCleanInstallDefaultsToGroq() {
        withIsolatedPreferences { preferences in
            // Frische Installation: weder Provider noch Modell gesetzt.
            preferences.selectedProviderRaw = nil
            preferences.selectedModelRaw = nil

            TranscriptionSettings.migrateIfNeeded()

            XCTAssertEqual(TranscriptionSettings.loadProvider(), .groq)
            XCTAssertEqual(TranscriptionSettings.loadModel(), .groq_whisper_v3)
        }
    }

    func testExistingOpenAIUserIsPreservedOnMigration() {
        withIsolatedPreferences { preferences in
            // Bestandsnutzer mit altem OpenAI-Wert, noch kein neues Modell.
            preferences.selectedProviderRaw = "openai_gpt4o"
            preferences.selectedModelRaw = nil

            TranscriptionSettings.migrateIfNeeded()

            XCTAssertEqual(TranscriptionSettings.loadProvider(), .openai)
            XCTAssertEqual(TranscriptionSettings.loadModel(), .openai_gpt4o)
        }
    }

    func testLoadDefaultsFallBackToGroqWhenUnset() {
        withIsolatedPreferences { preferences in
            preferences.selectedProviderRaw = nil
            preferences.selectedModelRaw = nil

            XCTAssertEqual(TranscriptionSettings.loadProvider(), .groq)
            XCTAssertEqual(TranscriptionSettings.loadModel(), .groq_whisper_v3)
        }
    }

    func testUsageProfileDefaultsToFullForExistingUsers() {
        withIsolatedPreferences { preferences in
            // Kein Profil gesetzt (Bestandsnutzer / frischer Zustand) → .full = heutiges Verhalten.
            XCTAssertEqual(preferences.usageProfile, .full)
        }
    }

    func testUsageProfilePersistsSelection() {
        withIsolatedPreferences { preferences in
            preferences.usageProfile = .dictationRaw
            XCTAssertEqual(preferences.usageProfile, .dictationRaw)

            preferences.usageProfile = .dictationEnrichment
            XCTAssertEqual(preferences.usageProfile, .dictationEnrichment)
        }
    }

    func testUsageProfileDerivedFlags() {
        XCTAssertFalse(AppUsageProfile.dictationRaw.wantsCodexEnrichment)
        XCTAssertFalse(AppUsageProfile.dictationRaw.wantsAgentChats)
        XCTAssertEqual(AppUsageProfile.dictationRaw.activationPolicy, .accessory)

        XCTAssertTrue(AppUsageProfile.dictationEnrichment.wantsCodexEnrichment)
        XCTAssertFalse(AppUsageProfile.dictationEnrichment.wantsAgentChats)
        XCTAssertEqual(AppUsageProfile.dictationEnrichment.activationPolicy, .accessory)

        XCTAssertTrue(AppUsageProfile.full.wantsCodexEnrichment)
        XCTAssertTrue(AppUsageProfile.full.wantsAgentChats)
        XCTAssertEqual(AppUsageProfile.full.activationPolicy, .regular)

        XCTAssertEqual(AppUsageProfile.defaultProfile, .full)
    }

    func testProviderDisplayOrderAndRecommendation() {
        XCTAssertEqual(TranscriptionProvider.displayOrder, [.groq, .openai])
        XCTAssertEqual(TranscriptionProvider.recommended, .groq)
        XCTAssertTrue(TranscriptionProvider.groq.isRecommended)
        XCTAssertFalse(TranscriptionProvider.openai.isRecommended)
        XCTAssertEqual(TranscriptionProvider.groq.recommendationBadge, "Free API key")
        XCTAssertNil(TranscriptionProvider.openai.recommendationBadge)
        XCTAssertNotNil(TranscriptionProvider.groq.recommendationHint)
        XCTAssertNil(TranscriptionProvider.openai.recommendationHint)
    }

    func testSaveModelAlsoUpdatesProvider() {
        withIsolatedPreferences { _ in
            TranscriptionSettings.saveModel(.groq_whisper_v3_turbo)

            XCTAssertEqual(TranscriptionSettings.loadProvider(), .groq)
            XCTAssertEqual(TranscriptionSettings.loadModel(), .groq_whisper_v3_turbo)
        }
    }

    func testPreferenceKeysRawNamesAreStable() {
        let keys: [(String, String)] = [
            ("selectedProvider", PreferenceKeys.selectedProvider),
            ("selectedModel", PreferenceKeys.selectedModel),
            ("usageProfile", PreferenceKeys.usageProfile),
            ("language", PreferenceKeys.language),
            ("autoPasteEnabled", PreferenceKeys.autoPasteEnabled),
            ("audioDuckingEnabled", PreferenceKeys.audioDuckingEnabled),
            ("audioDuckingFactor", PreferenceKeys.audioDuckingFactor),
            ("overlayStyle", PreferenceKeys.overlayStyle),
            ("overlayPositionX", PreferenceKeys.overlayPositionX),
            ("overlayPositionY", PreferenceKeys.overlayPositionY),
            ("selectedAudioDeviceUID", PreferenceKeys.selectedAudioDeviceUID),
            ("debugFileLoggingEnabled", PreferenceKeys.debugFileLoggingEnabled),
            ("defaultOutputModeID", PreferenceKeys.defaultOutputModeID),
            ("lastSelectedOutputModeID", PreferenceKeys.lastSelectedOutputModeID),
            ("fallbackToRawOnProcessingError", PreferenceKeys.fallbackToRawOnProcessingError),
            ("showModePickerInMiniOverlay", PreferenceKeys.showModePickerInMiniOverlay),
            ("showConfirmButtonInOverlay", PreferenceKeys.showConfirmButtonInOverlay),
            ("selectedContextCaptureEnabled", PreferenceKeys.selectedContextCaptureEnabled),
            ("visualContextCaptureEnabled", PreferenceKeys.visualContextCaptureEnabled),
            ("maxScreenshotsPerRecording", PreferenceKeys.maxScreenshotsPerRecording),
            ("didMigrateMaxScreenshotsPerRecordingTo20", PreferenceKeys.didMigrateMaxScreenshotsPerRecordingTo20),
            ("maxScreenRecordingDuration", PreferenceKeys.maxScreenRecordingDuration),
            ("deleteContextFilesAfterProcessing", PreferenceKeys.deleteContextFilesAfterProcessing),
            ("codexPostProcessingModel", PreferenceKeys.codexPostProcessingModel),
            ("codexReasoningEffort", PreferenceKeys.codexReasoningEffort),
            ("codexServiceTier", PreferenceKeys.codexServiceTier),
            ("codexVisualInputMode", PreferenceKeys.codexVisualInputMode),
            ("agentDefaultProjectPath", PreferenceKeys.agentDefaultProjectPath),
            ("defaultAgentProvider", PreferenceKeys.defaultAgentProvider),
            ("isAutoChatRenameEnabled", PreferenceKeys.isAutoChatRenameEnabled),
            ("isAutoSummaryEnabled", PreferenceKeys.isAutoSummaryEnabled),
            ("isTerminalBellEnabled", PreferenceKeys.isTerminalBellEnabled),
            ("codexExtraArguments", PreferenceKeys.codexExtraArguments),
            ("claudeExtraArguments", PreferenceKeys.claudeExtraArguments),
            ("claudeGPTBackendEnabled", PreferenceKeys.claudeGPTBackendEnabled),
            ("claudeGPTBackendPort", PreferenceKeys.claudeGPTBackendPort),
            ("claudeGPTRouterPort", PreferenceKeys.claudeGPTRouterPort),
            ("claudeGPTBackendDefaultModel", PreferenceKeys.claudeGPTBackendDefaultModel),
            ("claudeGPTPickerModel", PreferenceKeys.claudeGPTPickerModel),
            ("claudeGPTFastModeEnabled", PreferenceKeys.claudeGPTFastModeEnabled),
            ("claudeGPTSubagentModel", PreferenceKeys.claudeGPTSubagentModel),
            ("claudeGPTAutoCompactWindow", PreferenceKeys.claudeGPTAutoCompactWindow),
            ("appearanceOverride", PreferenceKeys.appearanceOverride),
            ("agentSidebarDragEnabled", PreferenceKeys.agentSidebarDragEnabled),
            ("agentEventDrivenWatchEnabled", PreferenceKeys.agentEventDrivenWatchEnabled),
            ("agentTerminalMetalEnabled", PreferenceKeys.agentTerminalMetalEnabled),
            ("agentStopSoundEnabled", PreferenceKeys.agentStopSoundEnabled),
            ("agentStopSoundName", PreferenceKeys.agentStopSoundName),
            ("claudeHooksEnabled", PreferenceKeys.claudeHooksEnabled),
            ("agentStopNotificationEnabled", PreferenceKeys.agentStopNotificationEnabled),
            ("agentAwaitingNotificationEnabled", PreferenceKeys.agentAwaitingNotificationEnabled),
            ("updateCheckEnabled", PreferenceKeys.updateCheckEnabled)
        ]

        XCTAssertEqual(keys.count, 52)
        for (expected, actual) in keys {
            XCTAssertEqual(actual, expected)
        }
    }

    func testAllAppPreferencesDefaultsIncludingHiddenSettings() {
        withIsolatedPreferencesAndDefaults { preferences, defaults in
            XCTAssertNil(preferences.selectedProviderRaw)
            XCTAssertNil(preferences.selectedModelRaw)
            XCTAssertEqual(preferences.usageProfile, .full)
            XCTAssertEqual(preferences.language, "de")
            XCTAssertTrue(preferences.isAutoPasteEnabled)
            XCTAssertTrue(preferences.isAudioDuckingEnabled)
            XCTAssertEqual(preferences.audioDuckingFactor, 0.2)
            defaults.set(0.0, forKey: PreferenceKeys.audioDuckingFactor)
            XCTAssertEqual(preferences.audioDuckingFactor, 0.2)
            XCTAssertEqual(preferences.overlayStyleRaw, OverlayStyle.mini.rawValue)
            XCTAssertNil(preferences.selectedAudioDeviceUID)
            XCTAssertEqual(preferences.appearanceOverride, .system)
            XCTAssertFalse(preferences.isDebugFileLoggingEnabled)
            // Beschlossen 2026-07-06: Erstinstallation startet mit Fast (raw) —
            // gespeicherte Werte bleiben unangetastet (siehe Folge-Asserts).
            XCTAssertEqual(preferences.defaultOutputModeID, OutputMode.rawID)
            XCTAssertEqual(preferences.lastSelectedOutputModeID, OutputMode.rawID)
            XCTAssertTrue(preferences.fallbackToRawOnProcessingError)
            XCTAssertTrue(preferences.showModePickerInMiniOverlay)
            XCTAssertTrue(preferences.showConfirmButtonInOverlay)
            XCTAssertTrue(preferences.isSelectedContextCaptureEnabled)
            XCTAssertTrue(preferences.isVisualContextCaptureEnabled)
            XCTAssertEqual(preferences.maxScreenshotsPerRecording, 20)
            defaults.set(0, forKey: PreferenceKeys.maxScreenshotsPerRecording)
            XCTAssertEqual(preferences.maxScreenshotsPerRecording, 20)
            XCTAssertEqual(preferences.maxScreenRecordingDuration, 30)
            defaults.set(0.0, forKey: PreferenceKeys.maxScreenRecordingDuration)
            XCTAssertEqual(preferences.maxScreenRecordingDuration, 30)
            XCTAssertFalse(preferences.deleteContextFilesAfterProcessing)
            XCTAssertEqual(preferences.codexPostProcessingModelRaw, CodexPostProcessingModel.defaultModel.rawValue)
            XCTAssertEqual(preferences.codexReasoningEffortRaw, CodexReasoningEffort.defaultEffort.rawValue)
            XCTAssertEqual(preferences.codexServiceTierRaw, CodexServiceTier.defaultTier.rawValue)
            XCTAssertEqual(preferences.codexVisualInputModeRaw, CodexVisualInputMode.defaultMode.rawValue)
            XCTAssertEqual(preferences.agentDefaultProjectPath, FileManager.default.homeDirectoryForCurrentUser.path)
            XCTAssertEqual(preferences.defaultAgentProviderRaw, "claude")
            XCTAssertEqual(preferences.defaultAgentLaunchTarget.provider, .claude)
            XCTAssertNil(preferences.defaultAgentLaunchTarget.kind)
            XCTAssertTrue(preferences.isAutoChatRenameEnabled)
            XCTAssertTrue(preferences.isAutoSummaryEnabled)
            XCTAssertTrue(preferences.isTerminalBellEnabled)
            XCTAssertEqual(preferences.codexExtraArguments, "")
            XCTAssertEqual(preferences.claudeExtraArguments, "")
            XCTAssertEqual(preferences.claudeGPTPickerModel, "")
            XCTAssertTrue(preferences.claudeGPTFastModeEnabled)
            XCTAssertFalse(preferences.isAgentTerminalMetalRendererEnabled)
            XCTAssertTrue(preferences.isAgentEventDrivenWatchEnabled)
            XCTAssertTrue(preferences.isAgentSidebarDragEnabled)
            XCTAssertTrue(preferences.isAgentStopSoundEnabled)
            XCTAssertEqual(preferences.agentStopSoundName, "Glass")
            XCTAssertTrue(preferences.isClaudeHooksEnabled)
            XCTAssertTrue(preferences.isAgentStopNotificationEnabled)
            XCTAssertTrue(preferences.isAgentAwaitingNotificationEnabled)
            XCTAssertTrue(preferences.isUpdateCheckEnabled)
        }
    }

    func testSavesAndLoadsAllCurrentPreferences() {
        withIsolatedPreferencesAndDefaults { preferences, defaults in
            preferences.selectedProviderRaw = TranscriptionProvider.openai.rawValue
            preferences.selectedModelRaw = TranscriptionModel.openai_whisper.rawValue
            preferences.usageProfile = .dictationEnrichment
            preferences.language = "en"
            preferences.isAutoPasteEnabled = false
            preferences.isAudioDuckingEnabled = false
            preferences.audioDuckingFactor = 0.35
            preferences.overlayStyleRaw = OverlayStyle.full.rawValue
            preferences.selectedAudioDeviceUID = "device-uid"
            preferences.appearanceOverride = .dark
            preferences.isDebugFileLoggingEnabled = true
            preferences.defaultOutputModeID = OutputMode.slackID
            preferences.lastSelectedOutputModeID = OutputMode.emailID
            preferences.fallbackToRawOnProcessingError = false
            preferences.showModePickerInMiniOverlay = false
            preferences.showConfirmButtonInOverlay = false
            preferences.isSelectedContextCaptureEnabled = false
            preferences.isVisualContextCaptureEnabled = false
            preferences.maxScreenshotsPerRecording = 7
            preferences.maxScreenRecordingDuration = 12
            preferences.deleteContextFilesAfterProcessing = true
            preferences.codexPostProcessingModelRaw = CodexPostProcessingModel.gpt52.rawValue
            preferences.codexReasoningEffortRaw = CodexReasoningEffort.high.rawValue
            preferences.codexServiceTierRaw = CodexServiceTier.standard.rawValue
            preferences.codexVisualInputModeRaw = CodexVisualInputMode.video.rawValue
            preferences.agentDefaultProjectPath = "/tmp/project"
            preferences.defaultAgentProviderRaw = "claude-agents"
            preferences.isAutoChatRenameEnabled = false
            preferences.isAutoSummaryEnabled = false
            preferences.isTerminalBellEnabled = false
            preferences.codexExtraArguments = "--ask-for-approval never"
            preferences.claudeExtraArguments = "--verbose"
            preferences.claudeGPTPickerModel = "gpt-5.6-luna-fast"
            preferences.claudeGPTFastModeEnabled = false
            preferences.isAgentTerminalMetalRendererEnabled = true
            preferences.isAgentEventDrivenWatchEnabled = false
            preferences.isAgentSidebarDragEnabled = false
            preferences.isAgentStopSoundEnabled = false
            preferences.agentStopSoundName = "Ping"
            preferences.isClaudeHooksEnabled = false
            preferences.isAgentStopNotificationEnabled = false
            preferences.isAgentAwaitingNotificationEnabled = false
            preferences.isUpdateCheckEnabled = false

            let loaded = AppPreferences(defaults: defaults)
            XCTAssertEqual(loaded.selectedProviderRaw, TranscriptionProvider.openai.rawValue)
            XCTAssertEqual(loaded.selectedModelRaw, TranscriptionModel.openai_whisper.rawValue)
            XCTAssertEqual(loaded.usageProfile, .dictationEnrichment)
            XCTAssertEqual(loaded.language, "en")
            XCTAssertFalse(loaded.isAutoPasteEnabled)
            XCTAssertFalse(loaded.isAudioDuckingEnabled)
            XCTAssertEqual(loaded.audioDuckingFactor, 0.35)
            XCTAssertEqual(loaded.overlayStyleRaw, OverlayStyle.full.rawValue)
            XCTAssertEqual(loaded.selectedAudioDeviceUID, "device-uid")
            XCTAssertEqual(loaded.appearanceOverride, .dark)
            XCTAssertTrue(loaded.isDebugFileLoggingEnabled)
            XCTAssertEqual(loaded.defaultOutputModeID, OutputMode.slackID)
            XCTAssertEqual(loaded.lastSelectedOutputModeID, OutputMode.emailID)
            XCTAssertFalse(loaded.fallbackToRawOnProcessingError)
            XCTAssertFalse(loaded.showModePickerInMiniOverlay)
            XCTAssertFalse(loaded.showConfirmButtonInOverlay)
            XCTAssertFalse(loaded.isSelectedContextCaptureEnabled)
            XCTAssertFalse(loaded.isVisualContextCaptureEnabled)
            XCTAssertEqual(loaded.maxScreenshotsPerRecording, 7)
            XCTAssertEqual(loaded.maxScreenRecordingDuration, 12)
            XCTAssertTrue(loaded.deleteContextFilesAfterProcessing)
            XCTAssertEqual(loaded.codexPostProcessingModelRaw, CodexPostProcessingModel.gpt52.rawValue)
            XCTAssertEqual(loaded.codexReasoningEffortRaw, CodexReasoningEffort.high.rawValue)
            XCTAssertEqual(loaded.codexServiceTierRaw, CodexServiceTier.standard.rawValue)
            XCTAssertEqual(loaded.codexVisualInputModeRaw, CodexVisualInputMode.video.rawValue)
            XCTAssertEqual(loaded.agentDefaultProjectPath, "/tmp/project")
            XCTAssertEqual(loaded.defaultAgentProviderRaw, "claude-agents")
            XCTAssertEqual(loaded.defaultAgentLaunchTarget.provider, .claude)
            XCTAssertEqual(loaded.defaultAgentLaunchTarget.kind, .agentView)
            XCTAssertFalse(loaded.isAutoChatRenameEnabled)
            XCTAssertFalse(loaded.isAutoSummaryEnabled)
            XCTAssertFalse(loaded.isTerminalBellEnabled)
            XCTAssertEqual(loaded.codexExtraArguments, "--ask-for-approval never")
            XCTAssertEqual(loaded.claudeExtraArguments, "--verbose")
            XCTAssertEqual(loaded.claudeGPTPickerModel, "gpt-5.6-luna-fast")
            XCTAssertFalse(loaded.claudeGPTFastModeEnabled)
            XCTAssertTrue(loaded.isAgentTerminalMetalRendererEnabled)
            XCTAssertFalse(loaded.isAgentEventDrivenWatchEnabled)
            XCTAssertFalse(loaded.isAgentSidebarDragEnabled)
            XCTAssertFalse(loaded.isAgentStopSoundEnabled)
            XCTAssertEqual(loaded.agentStopSoundName, "Ping")
            XCTAssertFalse(loaded.isClaudeHooksEnabled)
            XCTAssertFalse(loaded.isAgentStopNotificationEnabled)
            XCTAssertFalse(loaded.isAgentAwaitingNotificationEnabled)
            XCTAssertFalse(loaded.isUpdateCheckEnabled)
        }
    }

    func testScreenshotLimitMigrationPinsCurrentCasesAndDoesNotRunTwice() {
        let cases: [(initial: Int?, expectedStored: Int, expectedRead: Int)] = [
            (nil, 20, 20),
            (0, 20, 20),
            (3, 20, 20),
            (7, 7, 7),
            (21, 20, 20)
        ]

        for testCase in cases {
            withRawIsolatedDefaults { defaults in
                if let initial = testCase.initial {
                    defaults.set(initial, forKey: PreferenceKeys.maxScreenshotsPerRecording)
                }

                let preferences = AppPreferences(defaults: defaults)

                XCTAssertEqual(defaults.integer(forKey: PreferenceKeys.maxScreenshotsPerRecording), testCase.expectedStored)
                XCTAssertEqual(preferences.maxScreenshotsPerRecording, testCase.expectedRead)
                XCTAssertTrue(defaults.bool(forKey: PreferenceKeys.didMigrateMaxScreenshotsPerRecordingTo20))

                defaults.set(3, forKey: PreferenceKeys.maxScreenshotsPerRecording)
                _ = AppPreferences(defaults: defaults)

                // Das Migrationsflag ist heute die alleinige Sperre gegen einen zweiten Lauf.
                XCTAssertEqual(defaults.integer(forKey: PreferenceKeys.maxScreenshotsPerRecording), 3)
            }
        }
    }

    func testTranscriptionMigrationDoesNotOverwriteExistingSelectedModel() {
        withIsolatedPreferences { preferences in
            preferences.selectedProviderRaw = "openai_whisper"
            preferences.selectedModelRaw = TranscriptionModel.groq_whisper_v3_turbo.rawValue

            TranscriptionSettings.migrateIfNeeded()

            XCTAssertEqual(preferences.selectedProviderRaw, "openai_whisper")
            XCTAssertEqual(preferences.selectedModelRaw, TranscriptionModel.groq_whisper_v3_turbo.rawValue)
        }
    }

    func testDisablingVisualContextDoesNotResetVisualDetailPreferences() {
        withIsolatedPreferences { preferences in
            preferences.maxScreenshotsPerRecording = 7
            preferences.maxScreenRecordingDuration = 45
            preferences.deleteContextFilesAfterProcessing = true
            preferences.codexVisualInputModeRaw = CodexVisualInputMode.video.rawValue

            preferences.isVisualContextCaptureEnabled = false

            XCTAssertFalse(preferences.isVisualContextCaptureEnabled)
            XCTAssertEqual(preferences.maxScreenshotsPerRecording, 7)
            XCTAssertEqual(preferences.maxScreenRecordingDuration, 45)
            XCTAssertTrue(preferences.deleteContextFilesAfterProcessing)
            XCTAssertEqual(preferences.codexVisualInputModeRaw, CodexVisualInputMode.video.rawValue)
        }
    }

    func testUpdateCheckEnabledDefaultTrueAndFalsePersists() {
        withIsolatedPreferencesAndDefaults { preferences, defaults in
            XCTAssertTrue(preferences.isUpdateCheckEnabled)

            preferences.isUpdateCheckEnabled = false

            XCTAssertFalse(AppPreferences(defaults: defaults).isUpdateCheckEnabled)
        }
    }

    func testAutoSummaryEnabledDefaultTrueAndFalsePersists() {
        withIsolatedPreferencesAndDefaults { preferences, defaults in
            XCTAssertTrue(preferences.isAutoSummaryEnabled)

            preferences.isAutoSummaryEnabled = false

            XCTAssertFalse(AppPreferences(defaults: defaults).isAutoSummaryEnabled)
        }
    }

    func testAgentDefaultProjectPathDefaultsToHomeAndPersists() {
        withIsolatedPreferencesAndDefaults { preferences, defaults in
            XCTAssertEqual(preferences.agentDefaultProjectPath, FileManager.default.homeDirectoryForCurrentUser.path)

            preferences.agentDefaultProjectPath = "/tmp/whisperm8-project"

            XCTAssertEqual(AppPreferences(defaults: defaults).agentDefaultProjectPath, "/tmp/whisperm8-project")
        }
    }
}

private func withIsolatedPreferences(_ body: (AppPreferences) -> Void) {
    withIsolatedPreferencesAndDefaults { preferences, _ in
        body(preferences)
    }
}

private func withIsolatedPreferencesAndDefaults(_ body: (AppPreferences, UserDefaults) -> Void) {
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

    body(preferences, defaults)
}

private func withRawIsolatedDefaults(_ body: (UserDefaults) -> Void) {
    let suiteName = "WhisperM8Tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    body(defaults)
}
