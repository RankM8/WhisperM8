import Foundation
import XCTest
@testable import WhisperM8

private final class CancellingTranscriptionService: TranscriptionServiceProtocol {
    func transcribe(audioURL: URL, language: String?, audioDuration: TimeInterval?) async throws -> String {
        throw CancellationError()
    }
}

private final class AudioStopSpy: AudioRecordingStopping {
    let url: URL
    var stopCount = 0
    var onStop: (() -> Void)?
    init(url: URL) { self.url = url }
    func stopRecording() -> URL? {
        stopCount += 1
        onStop?()
        return url
    }
}

/// LR-DIK-018: Der Audiostopp wartet nicht auf den Kontext-Capture.
@MainActor
final class RecordingCoordinatorStopOrderTests: XCTestCase {
    func testStopStopsAudioBeforeAwaitingContext() async throws {
        let appState = AppState.shared
        let wasRecording = appState.isRecording
        let wasTranscribing = appState.isTranscribing
        defer {
            appState.isRecording = wasRecording
            appState.isTranscribing = wasTranscribing
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let audio = tempDir.appendingPathComponent("a.m4a")
        try Data([0, 1, 2, 3]).write(to: audio)

        let coordinator = RecordingCoordinator(
            appState: appState,
            failedRecordingsStore: FailedRecordingsStore(directoryURL: tempDir.appendingPathComponent("failed")),
            providerResolver: { .openai },
            modelResolver: { .openai_gpt4o },
            apiKeyResolver: { _ in "key" },
            transcriberFactory: { _, _, _ in CancellingTranscriptionService() }
        )
        let spy = AudioStopSpy(url: audio)
        coordinator.audioStopper = spy

        appState.isRecording = true
        appState.isTranscribing = false
        coordinator.recordingStartTime = Date().addingTimeInterval(-5)

        // Capture-Stub: läuft 800 ms und meldet sich dann ab (wie ein
        // hängender Transcript-Zugriff).
        var contextPendingAtAudioStop: Bool?
        coordinator.contextCaptureTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            coordinator.contextCaptureTask = nil
        }
        spy.onStop = { contextPendingAtAudioStop = coordinator.contextCaptureTask != nil }

        await coordinator.stopRecording()

        XCTAssertEqual(spy.stopCount, 1)
        XCTAssertEqual(contextPendingAtAudioStop, true, "Audio muss gestoppt sein, bevor auf den Kontext gewartet wird")
    }
}
