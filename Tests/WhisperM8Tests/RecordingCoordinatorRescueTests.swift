import Foundation
import XCTest
@testable import WhisperM8

private final class RecordingTranscriptionService: TranscriptionServiceProtocol {
    var transcribedURLs: [URL] = []
    func transcribe(audioURL: URL, language: String?, audioDuration: TimeInterval?) async throws -> String {
        transcribedURLs.append(audioURL)
        throw CancellationError()
    }
}

private final class RescueAudioStopSpy: AudioRecordingStopping {
    let url: URL?
    var stopCount = 0
    init(url: URL?) { self.url = url }
    func stopRecording() -> URL? {
        stopCount += 1
        return url
    }
}

/// LR-DIK-012 (späterer Retry) und LR-DIK-001 (Quit-Rettung).
@MainActor
final class RecordingCoordinatorRescueTests: XCTestCase {
    private var tempDir: URL!
    private var storeDir: URL!
    private var savedRecording = false
    private var savedTranscribing = false
    private var savedHasPreserved = false

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-rescue-\(UUID().uuidString)", isDirectory: true)
        storeDir = tempDir.appendingPathComponent("failed", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let appState = AppState.shared
        savedRecording = appState.isRecording
        savedTranscribing = appState.isTranscribing
        savedHasPreserved = appState.hasPreservedRecording
    }

    override func tearDownWithError() throws {
        let appState = AppState.shared
        appState.isRecording = savedRecording
        appState.isTranscribing = savedTranscribing
        appState.hasPreservedRecording = savedHasPreserved
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeAudio(_ name: String = "a.m4a") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data([0, 1, 2, 3]).write(to: url)
        return url
    }

    private func makeCoordinator(
        store: FailedRecordingsStore,
        service: TranscriptionServiceProtocol = RecordingTranscriptionService()
    ) -> RecordingCoordinator {
        RecordingCoordinator(
            appState: .shared,
            failedRecordingsStore: store,
            providerResolver: { .openai },
            modelResolver: { .openai_gpt4o },
            apiKeyResolver: { _ in "key" },
            transcriberFactory: { _, _, _ in service }
        )
    }

    // MARK: LR-DIK-012

    func testStorePersistsOutputModeAndListsAfterReinstantiation() throws {
        let audio = try makeAudio()
        _ = try FailedRecordingsStore(directoryURL: storeDir).preserve(
            audioURL: audio, audioDuration: 12, language: "de", errorMessage: "x", outputModeID: "email"
        )

        let reopened = FailedRecordingsStore(directoryURL: storeDir).list()

        XCTAssertEqual(reopened.count, 1)
        XCTAssertEqual(reopened.first?.metadata.outputModeID, "email")
        XCTAssertEqual(reopened.first?.metadata.language, "de")
    }

    func testOldSidecarWithoutOutputModeStillDecodes() throws {
        let json = """
        {"recordedAt":"2026-10-01T10:00:00Z","audioDuration":3,"language":"de","errorMessage":"e","originalFilename":"a.m4a"}
        """
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        try Data([1]).write(to: storeDir.appendingPathComponent("recording-1.m4a"))
        try Data(json.utf8).write(to: storeDir.appendingPathComponent("recording-1.m4a.json"))

        let list = FailedRecordingsStore(directoryURL: storeDir).list()

        XCTAssertEqual(list.count, 1)
        XCTAssertNil(list.first?.metadata.outputModeID)
    }

    func testRetryLastPreservedRecordingWorksAfterRestart() async throws {
        let audio = try makeAudio()
        let store = FailedRecordingsStore(directoryURL: storeDir)
        let preserved = try store.preserve(
            audioURL: audio, audioDuration: 7, language: "de", errorMessage: "Key falsch", outputModeID: OutputMode.defaultMode().id
        )

        // „Neustart": frischer Coordinator ohne pendingRetry.
        let service = RecordingTranscriptionService()
        let coordinator = makeCoordinator(store: store, service: service)
        XCTAssertTrue(AppState.shared.hasPreservedRecording, "Menüeintrag muss nach Neustart sichtbar sein")
        XCTAssertNil(coordinator.pendingRetry)

        AppState.shared.isRecording = false
        AppState.shared.isTranscribing = false
        await coordinator.retryLastPreservedRecording()

        XCTAssertEqual(service.transcribedURLs.map(\.lastPathComponent), [preserved.audioURL.lastPathComponent])
    }

    func testNoPreservedRecordingHidesMenuFlag() {
        let coordinator = makeCoordinator(store: FailedRecordingsStore(directoryURL: storeDir))
        coordinator.refreshPreservedRecordingFlag()
        XCTAssertFalse(AppState.shared.hasPreservedRecording)
    }

    // MARK: LR-DIK-001

    func testPrepareForTerminationPreservesRunningRecording() throws {
        let audio = try makeAudio()
        let store = FailedRecordingsStore(directoryURL: storeDir)
        let coordinator = makeCoordinator(store: store)
        let spy = RescueAudioStopSpy(url: audio)
        coordinator.audioStopper = spy

        AppState.shared.isRecording = true
        coordinator.recordingStartTime = Date().addingTimeInterval(-20)

        coordinator.prepareForTermination()

        XCTAssertEqual(spy.stopCount, 1)
        let list = store.list()
        XCTAssertEqual(list.count, 1, "Audio + Sidecar müssen im FailedRecordings-Ordner liegen")
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertGreaterThan(list[0].metadata.audioDuration, 15)
    }

    func testPrepareForTerminationPreservesInFlightUpload() throws {
        let audio = try makeAudio()
        let store = FailedRecordingsStore(directoryURL: storeDir)
        let coordinator = makeCoordinator(store: store)
        AppState.shared.isRecording = false
        coordinator.inFlightTranscription = InFlightTranscription(
            audioURL: audio, audioDuration: 30, outputMode: OutputMode.defaultMode(), contextBundle: .empty
        )

        coordinator.prepareForTermination()

        XCTAssertEqual(store.list().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    /// Review W2a: Cmd+Q, während der Stop schon gestoppt hat und auf den
    /// Kontext wartet — der Recorder liefert keine URL mehr.
    func testPrepareForTerminationDuringStopWindowPreservesStoppedAudio() throws {
        let audio = try makeAudio()
        let store = FailedRecordingsStore(directoryURL: storeDir)
        let coordinator = makeCoordinator(store: store)
        coordinator.audioStopper = RescueAudioStopSpy(url: nil)
        AppState.shared.isRecording = true
        coordinator.stoppedAudioAwaitingContext = (audio, 12)

        coordinator.prepareForTermination()

        XCTAssertEqual(store.list().count, 1)
        XCTAssertEqual(store.list().first?.metadata.audioDuration, 12)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    func testPrepareForTerminationDoesNothingWhenIdle() {
        let store = FailedRecordingsStore(directoryURL: storeDir)
        let coordinator = makeCoordinator(store: store)
        AppState.shared.isRecording = false

        coordinator.prepareForTermination()

        XCTAssertTrue(store.list().isEmpty)
    }
}
