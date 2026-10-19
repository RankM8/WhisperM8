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
        logPrefix: String,
        alertTitle: String = String(localized: "Transcription failed")
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

        let wantsRetry = showTranscriptionFailureAlert(title: alertTitle, message: message, canRetry: preserved)
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
                errorMessage: errorMessage,
                outputModeID: outputMode.id
            )
            pendingRetry = PendingTranscriptionRetry(
                recording: recording,
                audioDuration: audioDuration,
                outputMode: outputMode,
                contextBundle: contextBundle
            )
            Logger.transcription.info("Recording preserved at \(recording.audioURL.path, privacy: .public)")
            refreshPreservedRecordingFlag()
            return true
        } catch {
            Logger.transcription.error("Failed to preserve recording: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Fehler-Alert mit Retry-Option. Gibt `true` zurück, wenn der User
    /// "Erneut versuchen" gewählt hat.
    func showTranscriptionFailureAlert(title: String, message: String, canRetry: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.alertStyle = .warning
        if canRetry {
            alert.informativeText = message + "\n\n" + String(localized: "The recording was saved and can be transcribed again.")
            alert.addButton(withTitle: String(localized: "Try again"))
            alert.addButton(withTitle: String(localized: "Close"))
            return alert.runModal() == .alertFirstButtonReturn
        } else {
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            _ = alert.runModal()
            return false
        }
    }
}

// MARK: - Spätere Wiederholung (Menüleiste) und Quit-Rettung

extension RecordingCoordinator {
    /// Gibt es eine gesicherte Aufnahme, die sich erneut transkribieren lässt?
    /// Treibt die Sichtbarkeit des Menüleisten-Eintrags (`AppState`), damit
    /// der Menü-Body kein Disk-I/O macht.
    func refreshPreservedRecordingFlag() {
        appState?.hasPreservedRecording = !failedRecordingsStore.list().isEmpty
    }

    /// "Letzte Aufnahme erneut transkribieren": nimmt den gemerkten Lauf oder,
    /// nach App-Neustart, die neueste gesicherte Aufnahme samt Sidecar-Modus.
    /// Der Kontext ist nach einem Neustart weg (Bundle liegt nur im Speicher);
    /// Sprache, Modell und Anbieter kommen wie bei jedem Lauf aus den
    /// aktuellen Einstellungen — so hilft der Retry auch nach einer
    /// korrigierten API-Key-Eingabe.
    func retryLastPreservedRecording() async {
        guard let appState, !appState.isRecording, !appState.isTranscribing else { return }

        if let pending = pendingRetry,
           FileManager.default.fileExists(atPath: pending.recording.audioURL.path) {
            await retryPendingTranscription()
            return
        }

        guard let latest = failedRecordingsStore.list().first else {
            pendingRetry = nil
            refreshPreservedRecordingFlag()
            return
        }
        pendingRetry = PendingTranscriptionRetry(
            recording: latest,
            audioDuration: latest.metadata.audioDuration,
            outputMode: OutputMode.mode(for: latest.metadata.outputModeID),
            contextBundle: .empty
        )
        await retryPendingTranscription()
    }

    /// Synchrone Quit-Vorbereitung (LR-DIK-001), aus `applicationShouldTerminate`.
    /// Bewusst ohne `terminateLater`: finalisiert nur lokal eine laufende
    /// Aufnahme bzw. verschiebt das Audio eines laufenden Uploads in den
    /// FailedRecordings-Store, wartet nie auf Netzwerk und transkribiert/
    /// fügt nichts ein. Beim nächsten Start steht die Aufnahme im Menü bereit.
    func prepareForTermination() {
        guard let appState else { return }
        let message = "Die App wurde beendet, bevor das Diktat fertig war."

        if appState.isRecording {
            recordingTimer.stop()
            screenClipLimitTask?.cancel()
            contextCaptureTask?.cancel()
            let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? appState.recordingDuration
            // Im Stop-Fenster ist der Recorder schon gestoppt und liefert nil;
            // dann die dort gemerkte Datei retten.
            let pending = stoppedAudioAwaitingContext
            stoppedAudioAwaitingContext = nil
            if let audioURL = audioStopper.stopRecording() ?? pending?.url {
                preserveRecording(
                    audioURL: audioURL,
                    audioDuration: pending?.duration ?? duration,
                    outputMode: appState.selectedOutputMode,
                    contextBundle: appState.contextBundle,
                    errorMessage: message
                )
            }
            appState.isRecording = false
        } else if let flight = inFlightTranscription,
                  !isDeliveringTranscription,
                  FileManager.default.fileExists(atPath: flight.audioURL.path) {
            // Upload läuft: Datei ist fertig geschrieben, liegt aber noch im
            // tmp-Verzeichnis. Umziehen genügt, der Prozess endet ohnehin.
            preserveRecording(
                audioURL: flight.audioURL,
                audioDuration: flight.audioDuration,
                outputMode: flight.outputMode,
                contextBundle: flight.contextBundle,
                errorMessage: message
            )
        }
    }
}
