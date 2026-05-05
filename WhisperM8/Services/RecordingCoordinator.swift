import AppKit

@MainActor
final class RecordingCoordinator {
    private weak var appState: AppState?
    private let audioRecorder: AudioRecorder
    private let overlayController: OverlayController
    private let pasteService: PasteService
    private let recordingTimer: RecordingTimer

    private var recordingStartTime: Date?
    private var isProcessing = false
    private var escKeyMonitor: Any?

    init(
        appState: AppState
    ) {
        self.appState = appState
        self.audioRecorder = AudioRecorder()
        self.overlayController = OverlayController()
        self.pasteService = PasteService()
        self.recordingTimer = RecordingTimer()
    }

    func startRecording() async {
        guard let appState, !appState.isRecording, !appState.isTranscribing, !isProcessing else { return }

        isProcessing = true
        recordingTimer.stop()
        overlayController.hide()

        do {
            try await audioRecorder.startRecording()

            AudioDuckingManager.shared.duck()
            scheduleDuckingReinforcement()

            recordingStartTime = Date()
            appState.isRecording = true
            appState.recordingDuration = 0
            appState.audioLevel = 0
            appState.lastError = nil
            isProcessing = false

            overlayController.show(appState: appState) { [weak self] in
                self?.cancelRecording()
            }

            setupEscKeyMonitor()
            startDurationTimer()
        } catch {
            appState.lastError = error.localizedDescription
            isProcessing = false
        }
    }

    func stopRecording() async {
        guard let appState, appState.isRecording, !appState.isTranscribing, !isProcessing else {
            if let appState {
                Logger.debug("stopRecording guard failed: isRecording=\(appState.isRecording), isTranscribing=\(appState.isTranscribing), isProcessing=\(isProcessing)")
            }
            return
        }

        if let recordingStartTime {
            let elapsed = Date().timeIntervalSince(recordingStartTime)
            if elapsed < 0.3 {
                Logger.debug(" Recording too short: \(elapsed)s")
                return
            }
        }

        isProcessing = true
        let audioDuration = appState.recordingDuration
        Logger.debug(" Stopping recording. Duration: \(String(format: "%.1f", audioDuration))s")

        recordingTimer.stop()
        removeEscKeyMonitor()

        let audioURL = audioRecorder.stopRecording()
        appState.isRecording = false
        appState.audioLevel = 0
        recordingStartTime = nil

        Logger.debug("[RecordingCoordinator] Calling AudioDuckingManager.restore()")
        AudioDuckingManager.shared.restore()

        guard let audioURL else {
            Logger.debug(" ERROR: No audio URL returned from recorder")
            overlayController.hide()
            isProcessing = false
            showErrorAlert(title: "Recording Error", message: "No audio file was created.")
            return
        }

        logAudioFileAttributes(audioURL)

        appState.isTranscribing = true
        overlayController.update(appState: appState)

        do {
            try await transcribeAndDeliver(audioURL: audioURL, audioDuration: audioDuration)
        } catch let urlError as URLError {
            handleTranscriptionFailure(audioURL: audioURL, message: networkErrorMessage(for: urlError), logPrefix: "URL ERROR: \(urlError.code.rawValue)")
        } catch let transcriptionError as TranscriptionError {
            handleTranscriptionFailure(audioURL: audioURL, message: transcriptionError.errorDescription ?? "Unknown error", logPrefix: "TRANSCRIPTION ERROR")
        } catch {
            handleTranscriptionFailure(audioURL: audioURL, message: error.localizedDescription, logPrefix: "UNKNOWN ERROR: \(type(of: error))")
        }

        appState.isTranscribing = false
        isProcessing = false
        Logger.debug(" stopRecording completed")
    }

    func cancelRecording() {
        guard let appState, appState.isRecording else { return }

        recordingTimer.stop()
        removeEscKeyMonitor()

        let audioURL = audioRecorder.stopRecording()
        if let audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }

        appState.isRecording = false
        appState.audioLevel = 0
        recordingStartTime = nil

        AudioDuckingManager.shared.restore()
        overlayController.hide()

        Logger.paste.info("Recording cancelled by user")
    }

    var hasAccessibilityPermission: Bool {
        PermissionService.hasAccessibilityPermission
    }

    func requestAccessibilityPermission() {
        PermissionService.requestAccessibilityPermission()
    }

    private func transcribeAndDeliver(audioURL: URL, audioDuration: TimeInterval) async throws {
        guard let appState else { return }

        TranscriptionSettings.migrateIfNeeded()

        let provider = TranscriptionSettings.loadProvider()
        let model = TranscriptionSettings.loadModel()
        Logger.debug("Using provider: \(provider.rawValue), model: \(model.rawValue)")

        guard let apiKey = KeychainManager.load(key: provider.keychainKey), !apiKey.isEmpty else {
            Logger.debug("ERROR: No API key found for \(provider.keychainKey)")
            throw TranscriptionError.missingAPIKey
        }
        Logger.debug(" API key loaded (length: \(apiKey.count))")

        let language = AppPreferences.shared.language
        Logger.debug(" Language: \(language)")

        let service = provider.createService(apiKey: apiKey, model: model)
        Logger.debug(" Starting transcription...")

        let rawText = try await service.transcribe(
            audioURL: audioURL,
            language: language.isEmpty ? nil : language,
            audioDuration: audioDuration
        )
        let text = TextNormalizer.normalizeTranscriptionText(rawText)

        Logger.debug(" Transcription SUCCESS! Raw length: \(rawText.count), normalized length: \(text.count)")
        Logger.debug(" Text preview: \(String(text.prefix(100)))...")

        pasteService.copyToClipboard(text)
        appState.lastTranscription = text

        try? FileManager.default.removeItem(at: audioURL)

        if AppPreferences.shared.isAutoPasteEnabled {
            let previousApp = overlayController.getPreviousApp()
            overlayController.hide()
            pasteService.pasteToActiveApp(
                previousApp: previousApp,
                onMissingPermission: {
                    appState.lastError = "Accessibility permission required for auto-paste"
                    overlayController.hide()
                },
                onMissingTarget: {
                    overlayController.hide()
                }
            )
        } else {
            overlayController.hide()
            Logger.debug(" Auto-paste disabled, text copied to clipboard only")
        }
    }

    private func handleTranscriptionFailure(audioURL: URL, message: String, logPrefix: String) {
        appState?.lastError = message
        Logger.debug(" \(logPrefix): \(message)")
        overlayController.hide()
        try? FileManager.default.removeItem(at: audioURL)
        showErrorAlert(title: "Transcription Failed", message: message)
    }

    private func networkErrorMessage(for urlError: URLError) -> String {
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

    private func showErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func setupEscKeyMonitor() {
        removeEscKeyMonitor()

        escKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            if event.keyCode == 53, self.appState?.isRecording == true {
                Task { @MainActor in
                    self.cancelRecording()
                }
                return nil
            }

            return event
        }
    }

    private func removeEscKeyMonitor() {
        if let escKeyMonitor {
            NSEvent.removeMonitor(escKeyMonitor)
            self.escKeyMonitor = nil
        }
    }

    private func startDurationTimer() {
        recordingTimer.start { [weak self] in
            guard let self, let appState = self.appState else { return }

            if let recordingStartTime = self.recordingStartTime {
                appState.recordingDuration = Date().timeIntervalSince(recordingStartTime)
            } else {
                appState.recordingDuration = 0
            }

            appState.audioLevel = self.audioRecorder.audioLevel
            self.overlayController.update(appState: appState)
        }
    }

    private func scheduleDuckingReinforcement() {
        Task { @MainActor in
            for delay in [0.3, 0.6, 1.0, 1.5] {
                try? await Task.sleep(for: .seconds(delay))
                guard appState?.isRecording == true else { break }
                AudioDuckingManager.shared.duck()
            }
        }
    }

    private func logAudioFileAttributes(_ audioURL: URL) {
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
