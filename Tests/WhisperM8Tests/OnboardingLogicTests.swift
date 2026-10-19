import XCTest
import AVFoundation
@testable import WhisperM8

/// W3 „Erste Schritte": pure Onboarding-Logik (Abschluss-Gate, Schrittfolge,
/// Mikrofon-Aktion, Setup-fortsetzen, Key-Entwurf).
@MainActor
final class OnboardingLogicTests: XCTestCase {
    // MARK: LR-ONB-013

    func testWhitespaceOnlyKeyDoesNotSatisfyCredentialGate() {
        XCTAssertFalse(TranscriptionCredentialGate.isSatisfied(provider: .groq, typedKey: "   ", hasSavedKey: false))
        XCTAssertTrue(TranscriptionCredentialGate.isSatisfied(provider: .groq, typedKey: " abc ", hasSavedKey: false))
    }

    private func gate(
        outcome: OnboardingTestOutcome,
        keychainFailed: Bool = false,
        credentials: Bool = true
    ) -> OnboardingCompletionGate {
        OnboardingCompletionGate(
            micGranted: true, accessibilityGranted: true, hotkeySet: true,
            credentialsSatisfied: credentials, keychainWriteFailed: keychainFailed,
            testOutcome: outcome
        )
    }

    func testFailedTestNeverShowsAllSet() {
        let failed = gate(outcome: .failed("401 invalid api key"))
        XCTAssertFalse(failed.showsSuccess)
        XCTAssertEqual(failed.notice, .testFailed("401 invalid api key"))
        XCTAssertFalse(gate(outcome: .notRun).showsSuccess)
        XCTAssertEqual(gate(outcome: .notRun).notice, .untested)
        XCTAssertTrue(gate(outcome: .succeeded).showsSuccess)
    }

    func testKeychainFailureOrMissingCredentialsBlockFinish() {
        XCTAssertFalse(gate(outcome: .succeeded, keychainFailed: true).canFinish)
        XCTAssertFalse(gate(outcome: .notRun, credentials: false).canFinish)
        XCTAssertTrue(gate(outcome: .notRun).canFinish)
    }

    func testOutcomeDerivation() {
        XCTAssertEqual(OnboardingTestOutcome.derive(lastTranscription: nil, lastError: nil), .notRun)
        XCTAssertEqual(OnboardingTestOutcome.derive(lastTranscription: "hi", lastError: nil), .succeeded)
        XCTAssertEqual(OnboardingTestOutcome.derive(lastTranscription: "hi", lastError: "boom"), .failed("boom"))
    }

    // MARK: LR-ONB-003

    func testFullProfileHasClaudeStepButDictationProfilesDoNot() {
        XCTAssertTrue(OnboardingStepPlanner.steps(for: .full).contains(.claudeCLI))
        XCTAssertFalse(OnboardingStepPlanner.steps(for: .dictationRaw).contains(.claudeCLI))
        XCTAssertFalse(OnboardingStepPlanner.steps(for: .dictationEnrichment).contains(.claudeCLI))
        XCTAssertTrue(OnboardingStepPlanner.steps(for: .dictationRaw).contains(.language))
        XCTAssertEqual(OnboardingStepPlanner.steps(for: .dictationRaw).last, .test)
    }

    // MARK: LR-ONB-004

    func testDeniedMicrophoneOpensSystemSettingsInsteadOfRequesting() {
        XCTAssertEqual(MicrophoneOnboardingAction.decide(status: .denied), .openSystemSettings)
        XCTAssertEqual(MicrophoneOnboardingAction.decide(status: .restricted), .openSystemSettings)
        XCTAssertEqual(MicrophoneOnboardingAction.decide(status: .notDetermined), .request)
        XCTAssertNotNil(MicrophoneOnboardingAction.hint(status: .denied))
        XCTAssertNil(MicrophoneOnboardingAction.hint(status: .notDetermined))
    }

    // MARK: LR-ONB-005

    func testSetupIncompleteReason() {
        XCTAssertEqual(SetupIncompleteReason.evaluate(micGranted: true, accessibilityGranted: true, hotkeySet: false, hasCredentials: true), .hotkeyMissing)
        XCTAssertEqual(SetupIncompleteReason.evaluate(micGranted: true, accessibilityGranted: true, hotkeySet: true, hasCredentials: false), .credentialsMissing)
        XCTAssertNil(SetupIncompleteReason.evaluate(micGranted: true, accessibilityGranted: true, hotkeySet: true, hasCredentials: true))
    }

    // MARK: LR-ONB-006 / LR-ONB-007

    final class SpyStore: KeychainStoring {
        var values: [String: String] = [:]
        var saveCalls = 0
        var failSaves = false
        func save(key: String, value: String) -> KeychainSaveResult {
            saveCalls += 1
            if failSaves { return .failed(status: -25293) }
            values[key] = value
            return .saved
        }
        func load(key: String) -> String? { values[key] }
        func exists(key: String) -> Bool { values[key] != nil }
        func delete(key: String) { values[key] = nil }
    }

    func testTypingAndClearingNeverTouchesSavedKey() {
        let store = SpyStore()
        store.values["groqAPIKey"] = "good"
        let model = APIKeyDraftModel(keychainKey: "groqAPIKey", store: store)

        model.draft = "x"
        model.draft = ""

        XCTAssertEqual(store.saveCalls, 0)
        XCTAssertEqual(store.values["groqAPIKey"], "good")
        XCTAssertTrue(model.hasSavedKey)
    }

    func testCommitSavesTrimmedDraftAndClearsField() {
        let store = SpyStore()
        let model = APIKeyDraftModel(keychainKey: "k", store: store)
        model.draft = "  secret \n"

        XCTAssertTrue(model.commit())
        XCTAssertEqual(store.values["k"], "secret")
        XCTAssertTrue(model.hasSavedKey)
        XCTAssertEqual(model.draft, "")
    }

    func testFailedCommitKeepsDraftAndDoesNotClaimAccess() {
        let store = SpyStore()
        store.failSaves = true
        let model = APIKeyDraftModel(keychainKey: "k", store: store)
        model.draft = "secret"

        XCTAssertFalse(model.commit())
        XCTAssertFalse(model.hasSavedKey)
        XCTAssertEqual(model.draft, "secret")
        XCTAssertNotNil(model.saveError)
    }

    func testBlankDraftCannotBeCommitted() {
        let store = SpyStore()
        let model = APIKeyDraftModel(keychainKey: "k", store: store)
        model.draft = "   "
        XCTAssertFalse(model.canCommit)
        XCTAssertFalse(model.commit())
        XCTAssertEqual(store.saveCalls, 0)
    }
}
