import Foundation
import XCTest
@testable import WhisperM8

/// Rückmeldung am Controller und automatische Pause: Lichtleiste, Signal bei
/// wartendem Chat, Erkennung von Spielen.
final class ControllerFeedbackPolicyTests: XCTestCase {
    // MARK: - Lichtleiste

    func testRecordingWinsOverChatStatus() {
        XCTAssertEqual(
            ControllerLightPolicy.tone(isPaused: false, recordingPhase: .recording, targetStatus: .working), .red)
    }

    /// Grün heißt nur „arbeitet“ — wie bei den Status-Punkten der App.
    func testGreenOnlyWhileWorking() {
        for status in ControllerChatState.Status.allCases {
            let tone = ControllerLightPolicy.tone(isPaused: false, recordingPhase: nil, targetStatus: status)
            XCTAssertEqual(tone == .green, status == .working, "\(status)")
        }
    }

    func testAmberWhileQuestionIsOpen() {
        XCTAssertEqual(
            ControllerLightPolicy.tone(isPaused: false, recordingPhase: nil, targetStatus: .awaitingInput), .amber)
    }

    func testIdleWithoutChatAndWhileTranscribing() {
        XCTAssertEqual(ControllerLightPolicy.tone(isPaused: false, recordingPhase: nil, targetStatus: nil), .dimWhite)
        XCTAssertEqual(
            ControllerLightPolicy.tone(isPaused: false, recordingPhase: .transcribing, targetStatus: .idle), .dimWhite)
    }

    /// In der Pause schreibt die App nichts — die Farbe gehört dann dem Spiel.
    func testPausedWritesNothing() {
        XCTAssertNil(ControllerLightPolicy.tone(isPaused: true, recordingPhase: .recording, targetStatus: .working))
    }

    // MARK: - Wartender Chat

    private let a = UUID()
    private let b = UUID()

    func testNewlyWaitingChatSignalsOnce() {
        var tracker = ControllerWaitingTracker()
        XCTAssertTrue(tracker.update(awaiting: [a], visibleTarget: nil, isRecording: false, at: 0))
        XCTAssertFalse(tracker.update(awaiting: [a], visibleTarget: nil, isRecording: false, at: 20), "wartet weiter: kein neues Signal")
    }

    func testPrimedChatsDoNotSignal() {
        var tracker = ControllerWaitingTracker()
        tracker.prime(awaiting: [a])
        XCTAssertFalse(tracker.update(awaiting: [a], visibleTarget: nil, isRecording: false, at: 0))
        XCTAssertTrue(tracker.update(awaiting: [a, b], visibleTarget: nil, isRecording: false, at: 1))
    }

    func testVisibleTargetAndRecordingStaySilent() {
        var tracker = ControllerWaitingTracker()
        XCTAssertFalse(tracker.update(awaiting: [a], visibleTarget: a, isRecording: false, at: 0))
        XCTAssertFalse(tracker.update(awaiting: [a, b], visibleTarget: nil, isRecording: true, at: 1))
    }

    func testAtMostOneSignalInFiveSeconds() {
        var tracker = ControllerWaitingTracker()
        XCTAssertTrue(tracker.update(awaiting: [a], visibleTarget: nil, isRecording: false, at: 0))
        XCTAssertFalse(tracker.update(awaiting: [a, b], visibleTarget: nil, isRecording: false, at: 3))
        XCTAssertFalse(tracker.update(awaiting: [b], visibleTarget: nil, isRecording: false, at: 4))
        XCTAssertTrue(tracker.update(awaiting: [a, b], visibleTarget: nil, isRecording: false, at: 9))
    }

    // MARK: - Spiele

    func testGameDetection() {
        XCTAssertTrue(ControllerGameDetector.isGame(bundleID: "x", category: nil, supportsGameMode: true))
        XCTAssertTrue(ControllerGameDetector.isGame(bundleID: "x", category: "public.app-category.action-games", supportsGameMode: false))
        XCTAssertTrue(ControllerGameDetector.isGame(bundleID: "x", category: "public.app-category.games", supportsGameMode: false))
        XCTAssertTrue(ControllerGameDetector.isGame(bundleID: "com.valvesoftware.steam", category: nil, supportsGameMode: false))
        XCTAssertFalse(ControllerGameDetector.isGame(bundleID: "com.apple.Safari", category: "public.app-category.productivity", supportsGameMode: false))
        XCTAssertFalse(ControllerGameDetector.isGame(bundleID: nil, category: nil, supportsGameMode: false))
    }
}

/// Einmaliger Hinweis „Controller erkannt“.
final class ControllerConnectHintTests: XCTestCase {
    func testHintOnlyWhenFeatureAvailableUserOffAndNotShownYet() {
        XCTAssertTrue(ControllerConnectHint.shouldShow(featureEnabled: true, userEnabled: false, alreadyShown: false))
        XCTAssertFalse(ControllerConnectHint.shouldShow(featureEnabled: false, userEnabled: false, alreadyShown: false))
        XCTAssertFalse(ControllerConnectHint.shouldShow(featureEnabled: true, userEnabled: true, alreadyShown: false))
        XCTAssertFalse(ControllerConnectHint.shouldShow(featureEnabled: true, userEnabled: false, alreadyShown: true))
    }
}
