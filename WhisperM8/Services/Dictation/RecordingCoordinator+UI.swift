import Foundation
import AppKit

/// UI-/Utility-Helfer des RecordingCoordinator: Fehler-Alert, Netzwerk-
/// Fehlertexte, ESC-Key-Monitor, Aufnahme-Dauer-Timer und Audio-Datei-Logging.
/// Aus RecordingCoordinator.swift ausgelagert (Phase-2-Split).
extension RecordingCoordinator {
    func networkErrorMessage(for urlError: URLError) -> String {
        switch urlError.code {
        case .timedOut:
            return "Request timed out. The server took too long to respond."
        case .notConnectedToInternet:
            return "No internet connection."
        case .networkConnectionLost:
            return "Network connection was lost."
        case .cannotConnectToHost:
            return "Cannot connect to server."
        default:
            return "Network error: \(urlError.localizedDescription)"
        }
    }

    func showErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func setupEscKeyMonitor() {
        removeEscKeyMonitor()

        escKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            if event.keyCode == 53, self.appState?.isRecording == true {
                Task { @MainActor in
                    self.cancelRecording()
                }
                return nil
            }

            // ESC während der Nacharbeit bricht sie ab, wie der Knopf im
            // Overlay: der Rohtext wird eingefügt.
            if event.keyCode == 53, self.appState?.isPostProcessing == true {
                Task { @MainActor in
                    self.cancelPostProcessing()
                }
                return nil
            }

            // ESC während "Transcribing…" bricht den Upload ab; die Aufnahme
            // landet gesichert im FailedRecordings-Ordner. Der Task-Check
            // verhindert, dass ESC geschluckt wird, wenn kein Upload mehr
            // läuft (z. B. während der modale Fehler-Alert offen ist).
            if event.keyCode == 53, self.appState?.isTranscribing == true, self.transcriptionTask != nil {
                Task { @MainActor in
                    self.cancelTranscription()
                }
                return nil
            }

            return event
        }
    }

    /// Der Hotkey kam, während das letzte Diktat noch transkribiert oder
    /// nachgearbeitet wird. Nichts wird aufgenommen; das soll der Nutzer
    /// merken. Gedrückt gehaltene Tasten (Aufnahme läuft) und der kurze
    /// Mikrofonstart lösen keinen Hinweis aus.
    func signalBusyHotkeyPressIfNeeded(now: Date = Date()) {
        guard let appState, !appState.isRecording,
              appState.isTranscribing || appState.isPostProcessing else { return }
        let showNotice = lastBusyHotkeyNoticeAt.map { now.timeIntervalSince($0) >= 10 } ?? true
        if showNotice { lastBusyHotkeyNoticeAt = now }
        Logger.transcription.info("dictation_hotkey_ignored_busy postProcessing=\(appState.isPostProcessing, privacy: .public)")
        busyHotkeyNotifier(showNotice)
    }

    static func playBusySignal(showNotice: Bool) {
        if let sound = NSSound(named: "Funk") {
            sound.play()
        } else {
            NSSound.beep()
        }
        guard showNotice else { return }
        DictationNotice.post(
            title: String(localized: "Still working on your last dictation"),
            body: String(localized: "Nothing was recorded. Wait until the text is inserted, then press the hotkey again. Esc cancels the clean-up.")
        )
    }

    func removeEscKeyMonitor() {
        if let escKeyMonitor {
            NSEvent.removeMonitor(escKeyMonitor)
            self.escKeyMonitor = nil
        }
    }

    func startDurationTimer() {
        recordingTimer.start { [weak self] in
            guard let self, let appState = self.appState else { return }

            if let recordingStartTime = self.recordingStartTime {
                appState.recordingDuration = Date().timeIntervalSince(recordingStartTime)
            } else {
                appState.recordingDuration = 0
            }

            appState.audioLevel = self.audioRecorder.audioLevel
            // Engine-Laufzustand: fängt Geräteverlust/Ruhezustand ohne Notification ab.
            self.audioRecorder.checkEngineHealth()
            self.overlayController.update(appState: appState)
        }
    }

    func logAudioFileAttributes(_ audioURL: URL) {
        Logger.debug(" Audio file: \(audioURL.path)")

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
            let fileSize = attributes[.size] as? Int64 ?? 0
            let fileSizeMB = Double(fileSize) / (1024 * 1024)
            Logger.debug(" Audio file size: \(String(format: "%.2f", fileSizeMB)) MB")
        } catch {
            Logger.debug(" WARNING: Could not get file attributes: \(error)")
        }
    }
}
