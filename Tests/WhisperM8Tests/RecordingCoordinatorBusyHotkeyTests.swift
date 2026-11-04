import Foundation
import XCTest
@testable import WhisperM8

/// Hotkey während das letzte Diktat noch läuft: früher ging das zweite Diktat
/// still verloren. Jetzt gibt es einen Ton und höchstens alle 10 s eine
/// Mitteilung, aber nur in den Phasen Transkription und Nacharbeit.
@MainActor
final class RecordingCoordinatorBusyHotkeyTests: XCTestCase {
    private var signals: [Bool] = []

    private func makeCoordinator(appState: AppState) -> RecordingCoordinator {
        RecordingCoordinator(
            appState: appState,
            providerResolver: { .openai },
            modelResolver: { .openai_gpt4o },
            apiKeyResolver: { _ in nil },
            busyHotkeyNotifier: { [weak self] showNotice in self?.signals.append(showNotice) }
        )
    }

    private func withState(
        recording: Bool = false,
        transcribing: Bool = false,
        postProcessing: Bool = false,
        _ body: (AppState) -> Void
    ) {
        let appState = AppState.shared
        let saved = (appState.isRecording, appState.isTranscribing, appState.isPostProcessing)
        defer { (appState.isRecording, appState.isTranscribing, appState.isPostProcessing) = saved }
        appState.isRecording = recording
        appState.isTranscribing = transcribing
        appState.isPostProcessing = postProcessing
        body(appState)
    }

    func testPressDuringCleanUpSignalsWithNoticeAtMostEveryTenSeconds() {
        withState(postProcessing: true) { appState in
            let coordinator = makeCoordinator(appState: appState)
            let start = Date()
            coordinator.signalBusyHotkeyPressIfNeeded(now: start)
            coordinator.signalBusyHotkeyPressIfNeeded(now: start.addingTimeInterval(3))
            coordinator.signalBusyHotkeyPressIfNeeded(now: start.addingTimeInterval(11))
        }
        XCTAssertEqual(signals, [true, false, true])
    }

    func testPressDuringTranscriptionSignals() {
        withState(transcribing: true) { appState in
            makeCoordinator(appState: appState).signalBusyHotkeyPressIfNeeded()
        }
        XCTAssertEqual(signals, [true])
    }

    func testHeldKeyWhileRecordingOrIdleStaysSilent() {
        withState(recording: true) { appState in
            makeCoordinator(appState: appState).signalBusyHotkeyPressIfNeeded()
        }
        withState { appState in
            makeCoordinator(appState: appState).signalBusyHotkeyPressIfNeeded()
        }
        XCTAssertEqual(signals, [])
    }
}
