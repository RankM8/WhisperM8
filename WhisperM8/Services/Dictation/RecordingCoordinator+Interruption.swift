import Foundation

/// Der Recorder hat die Aufnahme von selbst beendet (Mikrofon weg, Engine nicht
/// neu startbar, Schreibfehler). Statt „No audio file was created“ wird die
/// Teilaufnahme über die vorhandene Rettungslogik gesichert und der Nutzer
/// informiert; „Erneut versuchen“ transkribiert, was aufgenommen wurde.
extension RecordingCoordinator {
    func handleRecorderInterruption(_ interruption: RecordingInterruption) {
        // Läuft schon ein Stop, holt dieser die Teilaufnahme selbst ab
        // (`AudioRecorder.stopRecording` liefert sie nach einer Unterbrechung).
        guard let appState, appState.isRecording, !appState.isTranscribing, !isProcessing else { return }

        Logger.transcription.info("recording_interrupted reason=\(String(describing: interruption), privacy: .public)")

        let audioDuration = appState.recordingDuration
        let frozenOutputMode = appState.selectedOutputMode
        let frozenContextBundle = appState.contextBundle

        recordingTimer.stop()
        removeEscKeyMonitor()
        stopClipboardScreenshotMonitor()
        screenClipLimitTask?.cancel()
        screenClipLimitTask = nil
        contextCaptureTask?.cancel()
        contextCaptureTask = nil

        let audioURL = audioRecorder.stopRecording()

        appState.isRecording = false
        appState.audioLevel = 0
        appState.isPostProcessing = false
        appState.postProcessingStatusText = nil
        appState.selectedContext = .empty
        appState.contextBundle = .empty
        appState.isScreenClipRecording = false
        recordingStartTime = nil

        Task { await visualContextCaptureService.cancelActiveClip() }
        AudioDuckingManager.shared.endCapture()

        let reason = Self.userMessage(for: interruption)
        guard let audioURL else {
            overlayController.hide()
            showErrorAlert(title: "Recording Interrupted", message: reason + " Es wurde noch kein Audio aufgenommen.")
            return
        }

        handleTranscriptionFailure(
            audioURL: audioURL,
            audioDuration: audioDuration,
            outputMode: frozenOutputMode,
            contextBundle: frozenContextBundle,
            message: reason + " Die bisherige Aufnahme wurde gesichert.",
            logPrefix: "Recording interrupted"
        )
    }

    private static func userMessage(for interruption: RecordingInterruption) -> String {
        switch interruption {
        case .deviceLost:
            return "Das Mikrofon ist nicht mehr verfügbar, die Aufnahme wurde beendet."
        case .engineFailed:
            return "Die Aufnahme konnte nach einem Gerätewechsel nicht fortgesetzt werden."
        case .writeFailed:
            return "Die Aufnahme konnte nicht weiter gespeichert werden (Speicherplatz?)."
        }
    }
}
