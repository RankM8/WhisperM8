import Foundation
import AppKit

/// Fehler-/Abbruch-Pfade des RecordingCoordinator: Transkription
/// fehlgeschlagen/abgebrochen, Aufnahme aufbewahren (kein Datenverlust) und
/// Retry-Alert. Aus RecordingCoordinator.swift ausgelagert (Phase-2-Split).
extension RecordingCoordinator {
    /// Misserfolg-Pfad: Aufnahme aufbewahren (nie löschen!) und Retry anbieten.
    /// Vor diesem Fix wurde die M4A hier sofort gelöscht — ein Netz-Timeout
    /// nach einem langen Diktat war damit unwiederbringlicher Datenverlust.
    func handleTranscriptionFailure(
        audioURL: URL,
        audioDuration: TimeInterval,
        outputMode: OutputMode,
        contextBundle: TranscriptContextBundle,
        message: String,
        logPrefix: String
    ) {
        appState?.lastError = message
        Logger.debug(" \(logPrefix): \(message)")
        overlayController.hide()

        let preserved = preserveRecording(
            audioURL: audioURL,
            audioDuration: audioDuration,
            outputMode: outputMode,
            contextBundle: contextBundle,
            errorMessage: message
        )

        let wantsRetry = showTranscriptionFailureAlert(message: message, canRetry: preserved)
        if wantsRetry {
            // Eigener Task statt direktem Call: Der Aufrufer (stopRecording/
            // retryPendingTranscription) muss erst seinen State-Cleanup
            // beenden, bevor der Retry die Guards passieren kann.
            Task { @MainActor [weak self] in
                await self?.retryPendingTranscription()
            }
        }
    }

    /// User-Abbruch während "Transcribing…": kein Fehler-Alert, aber die
    /// Aufnahme wird trotzdem gesichert — ein versehentliches ESC darf kein
    /// Diktat kosten.
    func handleTranscriptionCancelled(
        audioURL: URL,
        audioDuration: TimeInterval,
        outputMode: OutputMode,
        contextBundle: TranscriptContextBundle
    ) {
        Logger.transcription.info("Transcription aborted by user; preserving recording")
        appState?.lastError = nil
        overlayController.hide()
        preserveRecording(
            audioURL: audioURL,
            audioDuration: audioDuration,
            outputMode: outputMode,
            contextBundle: contextBundle,
            errorMessage: "Vom Benutzer abgebrochen"
        )
    }

    /// Verschiebt die Aufnahme in den FailedRecordings-Store und merkt sich
    /// den Lauf für "Erneut versuchen". Schlägt selbst das Sichern fehl,
    /// bleibt die Datei wenigstens unangetastet im tmp-Verzeichnis liegen.
    @discardableResult
    func preserveRecording(
        audioURL: URL,
        audioDuration: TimeInterval,
        outputMode: OutputMode,
        contextBundle: TranscriptContextBundle,
        errorMessage: String
    ) -> Bool {
        do {
            let recording = try failedRecordingsStore.preserve(
                audioURL: audioURL,
                audioDuration: audioDuration,
                language: AppPreferences.shared.language,
                errorMessage: errorMessage
            )
            pendingRetry = PendingTranscriptionRetry(
                recording: recording,
                audioDuration: audioDuration,
                outputMode: outputMode,
                contextBundle: contextBundle
            )
            Logger.transcription.info("Recording preserved at \(recording.audioURL.path, privacy: .public)")
            return true
        } catch {
            Logger.transcription.error("Failed to preserve recording: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Fehler-Alert mit Retry-Option. Gibt `true` zurück, wenn der User
    /// "Erneut versuchen" gewählt hat.
    func showTranscriptionFailureAlert(message: String, canRetry: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Transcription Failed"
        alert.alertStyle = .warning
        if canRetry {
            alert.informativeText = message + "\n\nDie Aufnahme wurde gesichert und kann erneut transkribiert werden."
            alert.addButton(withTitle: "Erneut versuchen")
            alert.addButton(withTitle: "Schließen")
            return alert.runModal() == .alertFirstButtonReturn
        } else {
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            _ = alert.runModal()
            return false
        }
    }
}
