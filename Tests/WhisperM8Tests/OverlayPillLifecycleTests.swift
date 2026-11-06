import AppKit
import XCTest
@testable import WhisperM8

/// Tote Pill (05.11.2026): Tests treiben den echten Coordinator an, und der
/// öffnete unter `swift test` ein echtes Pill-Fenster. Hing der Testprozess
/// danach, blieb die Pill eingefroren auf dem Bildschirm, ✕ ohne Wirkung.
@MainActor
final class OverlayPillLifecycleTests: XCTestCase {
    private var tempDir: URL!
    private var savedRecording = false
    private var savedTranscribing = false
    private var savedPostProcessing = false
    private var savedHasPreserved = false

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pill-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let appState = AppState.shared
        savedRecording = appState.isRecording
        savedTranscribing = appState.isTranscribing
        savedPostProcessing = appState.isPostProcessing
        savedHasPreserved = appState.hasPreservedRecording
    }

    override func tearDownWithError() throws {
        let appState = AppState.shared
        appState.isRecording = savedRecording
        appState.isTranscribing = savedTranscribing
        appState.isPostProcessing = savedPostProcessing
        appState.hasPreservedRecording = savedHasPreserved
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Hält fest, was während des laufenden Uploads auf dem Bildschirm stand.
    private final class ProbingTranscriptionService: TranscriptionServiceProtocol {
        var probe: () -> Void = {}
        func transcribe(audioURL: URL, language: String?, audioDuration: TimeInterval?) async throws -> String {
            // Wie ein echter Upload: die Runloop läuft weiter, erst dann steht
            // ein Fenster auch beim WindowServer.
            try? await Task.sleep(for: .milliseconds(300))
            probe()
            throw CancellationError()
        }
    }

    /// Sichtbare Fenster dieses Prozesses in Pill-Panel-Größe (WindowServer-Sicht).
    private func onscreenPillWindows() -> Int {
        let pid = ProcessInfo.processInfo.processIdentifier
        let size = OverlayFrameResolver.panelSize
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter { info in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return false }
            return (bounds["Width"] as? Double) == Double(size.width)
                && (bounds["Height"] as? Double) == Double(size.height)
        }.count
    }

    private func makeCoordinator(service: TranscriptionServiceProtocol) -> RecordingCoordinator {
        RecordingCoordinator(
            appState: .shared,
            failedRecordingsStore: FailedRecordingsStore(directoryURL: tempDir.appendingPathComponent("failed")),
            providerResolver: { .openai },
            modelResolver: { .openai_gpt4o },
            apiKeyResolver: { _ in "key" },
            transcriberFactory: { _, _, _ in service }
        )
    }

    // MARK: Kein echtes Fenster aus dem Testprozess

    /// Vorher: Während „Transkription“ stand ein echtes Pill-Fenster des
    /// Testprozesses auf dem Bildschirm (genau die tote Pill: 00:00, Fast).
    func testRetryUnderTestShowsPillLogicallyButOpensNoWindow() async throws {
        let audio = tempDir.appendingPathComponent("a.m4a")
        try Data([0, 1, 2, 3]).write(to: audio)
        let store = FailedRecordingsStore(directoryURL: tempDir.appendingPathComponent("failed"))
        _ = try store.preserve(
            audioURL: audio, audioDuration: 7, language: "de", errorMessage: "x",
            outputModeID: OutputMode.defaultMode().id
        )
        let service = ProbingTranscriptionService()
        let coordinator = makeCoordinator(service: service)
        var windowsDuringUpload: Int?
        var presentedDuringUpload: Bool?
        service.probe = {
            windowsDuringUpload = self.onscreenPillWindows()
            presentedDuringUpload = coordinator.overlayController.isPresented
        }
        AppState.shared.isRecording = false
        AppState.shared.isTranscribing = false

        await coordinator.retryLastPreservedRecording()

        XCTAssertEqual(presentedDuringUpload, true, "Die Pill gilt während des Uploads als gezeigt")
        XCTAssertEqual(windowsDuringUpload, 0, "Unter swift test darf kein Pill-Fenster aufgehen")
        XCTAssertFalse(coordinator.overlayController.isPresented, "Nach dem Abbruch ist die Pill zu")
    }

    func testOverlayControllerOutsideTheAppOpensNoWindow() {
        let controller = OverlayController()
        XCTAssertFalse(controller.presentsWindow)

        controller.showQuickActionWorking(label: "Korrigiere…") {}

        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(onscreenPillWindows(), 0)
        controller.hide()
        XCTAssertFalse(controller.isPresented)
    }

    // MARK: ✕ schließt die Pill in jedem Zustand

    /// Vorher: Steht die Pill in „Transkription“, läuft aber kein Upload mehr,
    /// kehrte ✕ (`cancelTranscription`) sofort zurück und die Pill blieb.
    func testCancelInTranscribingPhaseWithoutUploadClosesPill() {
        let coordinator = makeCoordinator(service: ProbingTranscriptionService())
        AppState.shared.isRecording = false
        AppState.shared.isTranscribing = false
        coordinator.presentOverlay(appState: .shared)
        let overlay = coordinator.overlayController
        overlay.isTranscribing = true   // Phase der toten Pill
        XCTAssertEqual(overlay.phase, .transcribing)

        overlay.cancelTranscription()

        XCTAssertFalse(overlay.isPresented)
    }

    func testCancelInRecordingPhaseWithoutRecordingClosesPill() {
        let coordinator = makeCoordinator(service: ProbingTranscriptionService())
        AppState.shared.isRecording = false
        AppState.shared.isTranscribing = false
        coordinator.presentOverlay(appState: .shared)

        coordinator.overlayController.cancelRecording()

        XCTAssertFalse(coordinator.overlayController.isPresented)
    }

    func testCancelInImprovingPhaseWithoutPostProcessingClosesPill() {
        let coordinator = makeCoordinator(service: ProbingTranscriptionService())
        AppState.shared.isRecording = false
        AppState.shared.isTranscribing = false
        AppState.shared.isPostProcessing = false
        coordinator.presentOverlay(appState: .shared)

        coordinator.overlayController.cancelPostProcessing()

        XCTAssertFalse(coordinator.overlayController.isPresented)
    }

    /// Ohne verdrahteten Abbruch-Weg schließt ✕ direkt.
    func testCancelWithoutWiredCallbackClosesPill() {
        let controller = OverlayController(presentsWindow: false)
        controller.showQuickActionHint("Erst Text markieren", duration: 60)
        XCTAssertTrue(controller.isPresented)

        controller.cancelPostProcessing()

        XCTAssertFalse(controller.isPresented)
    }
}
