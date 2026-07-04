import AppKit
import XCTest
@testable import WhisperM8

private struct ClipboardSentinelError: Error {}

private final class ClipboardStubTranscriptionService: TranscriptionServiceProtocol {
    func transcribe(audioURL: URL, language: String?, audioDuration: TimeInterval?) async throws -> String {
        throw ClipboardSentinelError()
    }
}

/// Copy-to-Context: kopierter Text muss auch WÄHREND der Verarbeitung
/// (Transcribing/Improving) noch im Kontext-Bundle landen — der 500-ms-Monitor
/// läuft seit dem Pill-Neubau über den Stop hinaus und das Post-Processing
/// liest das Live-Bundle.
@MainActor
final class RecordingCoordinatorClipboardTests: XCTestCase {
    private func makeCoordinator(appState: AppState) -> RecordingCoordinator {
        RecordingCoordinator(
            appState: appState,
            providerResolver: { .openai },
            modelResolver: { .openai_gpt4o },
            apiKeyResolver: { _ in nil },
            transcriberFactory: { _, _, _ in ClipboardStubTranscriptionService() }
        )
    }

    /// Privates Pasteboard, damit die Tests nie das echte User-Clipboard anfassen.
    private func makePasteboard(text: String) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("wm8-clipboard-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard
    }

    func testImportClipboardTextLandsInContextDuringTranscription() {
        let appState = AppState.shared
        let originalBundle = appState.contextBundle
        let originalSelected = appState.selectedContext
        let wasRecording = appState.isRecording
        let wasTranscribing = appState.isTranscribing
        defer {
            appState.contextBundle = originalBundle
            appState.selectedContext = originalSelected
            appState.isRecording = wasRecording
            appState.isTranscribing = wasTranscribing
        }

        appState.isRecording = false
        appState.isTranscribing = true
        appState.contextBundle = .empty
        appState.selectedContext = .empty

        let coordinator = makeCoordinator(appState: appState)
        let pasteboard = makePasteboard(text: "Kopiert während der Transkription")

        let added = coordinator.importClipboardText(from: pasteboard)

        XCTAssertTrue(added, "Text-Import darf in der Transcribing-Phase nicht verweigert werden")
        XCTAssertTrue(appState.contextBundle.selectedText.text.contains("Kopiert während der Transkription"))
        XCTAssertFalse(appState.contextBundle.isEmpty)
    }

    func testImportClipboardTextAppendsInsteadOfOverwriting() {
        let appState = AppState.shared
        let originalBundle = appState.contextBundle
        let originalSelected = appState.selectedContext
        let wasRecording = appState.isRecording
        defer {
            appState.contextBundle = originalBundle
            appState.selectedContext = originalSelected
            appState.isRecording = wasRecording
        }

        appState.isRecording = true
        var bundle = TranscriptContextBundle.empty
        bundle.selectedText = SelectedContext(
            text: "Erster Ausschnitt",
            sourceAppName: nil,
            sourceBundleIdentifier: nil
        )
        appState.contextBundle = bundle

        let coordinator = makeCoordinator(appState: appState)
        let pasteboard = makePasteboard(text: "Zweiter Ausschnitt")

        XCTAssertTrue(coordinator.importClipboardText(from: pasteboard))
        XCTAssertTrue(appState.contextBundle.selectedText.text.contains("Erster Ausschnitt"))
        XCTAssertTrue(appState.contextBundle.selectedText.text.contains("Zweiter Ausschnitt"))

        // Identischer Inhalt wird nicht doppelt angehängt.
        let duplicate = makePasteboard(text: "Zweiter Ausschnitt")
        XCTAssertFalse(coordinator.importClipboardText(from: duplicate))
    }
}
