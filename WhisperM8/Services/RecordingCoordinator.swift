import AppKit

@MainActor
final class RecordingCoordinator {
    private weak var appState: AppState?
    private let audioRecorder: AudioRecorder
    private let overlayController: OverlayController
    private let pasteService: PasteService
    private let recordingTimer: RecordingTimer
    private let postProcessingService: PostProcessingService
    private let selectedContextService: SelectedContextService
    private let visualContextCaptureService: VisualContextCaptureService

    private var recordingStartTime: Date?
    private var isProcessing = false
    private var escKeyMonitor: Any?
    private var contextSourceApp: NSRunningApplication?
    private var screenClipLimitTask: Task<Void, Never>?

    init(
        appState: AppState,
        postProcessingService: PostProcessingService = PostProcessingService(),
        selectedContextService: SelectedContextService = SelectedContextService(),
        visualContextCaptureService: VisualContextCaptureService? = nil
    ) {
        self.appState = appState
        self.audioRecorder = AudioRecorder()
        self.overlayController = OverlayController()
        self.pasteService = PasteService()
        self.recordingTimer = RecordingTimer()
        self.postProcessingService = postProcessingService
        self.selectedContextService = selectedContextService
        self.visualContextCaptureService = visualContextCaptureService ?? VisualContextCaptureService()
    }

    func startRecording() async {
        guard let appState, !appState.isRecording, !appState.isTranscribing, !isProcessing else { return }

        isProcessing = true
        recordingTimer.stop()
        overlayController.hide()
        contextSourceApp = NSWorkspace.shared.frontmostApplication

        do {
            let selectedContext = await selectedContextService.capture(from: contextSourceApp)
            let contextBundle = TranscriptContextBundle.from(selectedContext: selectedContext, sourceApp: contextSourceApp)
            try await audioRecorder.startRecording()

            AudioDuckingManager.shared.duck()
            scheduleDuckingReinforcement()

            recordingStartTime = Date()
            appState.isRecording = true
            appState.recordingDuration = 0
            appState.audioLevel = 0
            appState.lastError = nil
            appState.isPostProcessing = false
            appState.selectedOutputMode = OutputMode.defaultMode()
            appState.selectedContext = selectedContext
            appState.lastSelectedContext = selectedContext.isEmpty ? nil : selectedContext
            appState.contextBundle = contextBundle
            appState.lastContextBundle = contextBundle.isEmpty ? nil : contextBundle
            appState.isScreenClipRecording = false
            isProcessing = false

            overlayController.show(
                appState: appState,
                onCancel: { [weak self] in
                    self?.cancelRecording()
                },
                onOutputModeChange: { [weak appState] mode in
                    appState?.setOutputMode(mode)
                },
                onAddScreenshot: { [weak self] in
                    self?.addContextScreenshot()
                },
                onToggleScreenClip: { [weak self] in
                    self?.toggleScreenClip()
                },
                onClearContext: { [weak self] in
                    self?.clearContextBundle()
                }
            )

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
        if appState.isScreenClipRecording {
            await stopScreenClipAndAttach()
        }

        let audioDuration = appState.recordingDuration
        let frozenOutputMode = appState.selectedOutputMode
        let frozenContextBundle = appState.contextBundle
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
        appState.lastOutputMode = frozenOutputMode
        overlayController.update(appState: appState)

        do {
            try await transcribeAndDeliver(
                audioURL: audioURL,
                audioDuration: audioDuration,
                outputMode: frozenOutputMode,
                contextBundle: frozenContextBundle
            )
        } catch let urlError as URLError {
            handleTranscriptionFailure(audioURL: audioURL, message: networkErrorMessage(for: urlError), logPrefix: "URL ERROR: \(urlError.code.rawValue)")
        } catch let transcriptionError as TranscriptionError {
            handleTranscriptionFailure(audioURL: audioURL, message: transcriptionError.errorDescription ?? "Unknown error", logPrefix: "TRANSCRIPTION ERROR")
        } catch {
            handleTranscriptionFailure(audioURL: audioURL, message: error.localizedDescription, logPrefix: "UNKNOWN ERROR: \(type(of: error))")
        }

        appState.isTranscribing = false
        appState.isPostProcessing = false
        appState.selectedContext = .empty
        appState.contextBundle = .empty
        appState.isScreenClipRecording = false
        isProcessing = false
        Logger.debug(" stopRecording completed")
    }

    func cancelRecording() {
        guard let appState, appState.isRecording else { return }

        recordingTimer.stop()
        removeEscKeyMonitor()
        screenClipLimitTask?.cancel()
        screenClipLimitTask = nil

        let audioURL = audioRecorder.stopRecording()
        if let audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }

        appState.isRecording = false
        appState.audioLevel = 0
        appState.isPostProcessing = false
        appState.selectedContext = .empty
        appState.contextBundle = .empty
        appState.isScreenClipRecording = false
        recordingStartTime = nil

        Task {
            await visualContextCaptureService.cancelActiveClip()
        }
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

    func addContextScreenshot() {
        guard let appState, appState.isRecording, !appState.isTranscribing, !appState.isPostProcessing else { return }
        guard appState.contextBundle.screenshots.count < AppPreferences.shared.maxScreenshotsPerRecording else {
            appState.lastError = "Maximum screenshots for this recording reached."
            return
        }

        Task { @MainActor in
            do {
                let screenshot = try await visualContextCaptureService.captureScreenshot(sourceApp: contextSourceApp)
                appState.contextBundle.screenshots.append(screenshot)
                appState.lastContextBundle = appState.contextBundle
                overlayController.update(appState: appState)
            } catch {
                appState.lastError = error.localizedDescription
                Logger.permission.warning("Visual screenshot context failed: \(error.localizedDescription, privacy: .public)")
                if error as? VisualContextCaptureError == .missingPermission {
                    _ = PermissionService.requestScreenRecordingPermission()
                }
                overlayController.update(appState: appState)
            }
        }
    }

    func toggleScreenClip() {
        guard let appState, appState.isRecording, !appState.isTranscribing, !appState.isPostProcessing else { return }

        Task { @MainActor in
            if appState.isScreenClipRecording {
                await stopScreenClipAndAttach()
            } else {
                await startScreenClip()
            }
        }
    }

    func clearContextBundle() {
        guard let appState, appState.isRecording, !appState.isScreenClipRecording else { return }
        visualContextCaptureService.cleanup(appState.contextBundle)
        appState.contextBundle = TranscriptContextBundle.from(selectedContext: .empty, sourceApp: contextSourceApp)
        appState.selectedContext = .empty
        appState.lastContextBundle = nil
        appState.lastSelectedContext = nil
        overlayController.update(appState: appState)
    }

    private func transcribeAndDeliver(
        audioURL: URL,
        audioDuration: TimeInterval,
        outputMode: OutputMode,
        contextBundle: TranscriptContextBundle
    ) async throws {
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
        let normalizedRawText = TextNormalizer.normalizeTranscriptionText(rawText)

        Logger.debug(" Transcription SUCCESS! Raw length: \(rawText.count), normalized length: \(normalizedRawText.count)")
        Logger.debug(" Text preview: \(String(normalizedRawText.prefix(100)))...")

        appState.lastRawTranscription = normalizedRawText

        let finalText = try await processTranscriptIfNeeded(
            normalizedRawText,
            mode: outputMode,
            language: language,
            contextBundle: contextBundle
        )

        pasteService.copyToClipboard(finalText)
        appState.lastFinalTranscription = finalText
        appState.lastTranscription = finalText

        try? FileManager.default.removeItem(at: audioURL)
        visualContextCaptureService.cleanup(contextBundle)

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

    private func processTranscriptIfNeeded(
        _ rawText: String,
        mode: OutputMode,
        language: String,
        contextBundle: TranscriptContextBundle
    ) async throws -> String {
        guard let appState else { return rawText }

        guard mode.usesPostProcessing else {
            return rawText
        }

        appState.isTranscribing = false
        appState.isPostProcessing = true
        overlayController.update(appState: appState)

        do {
            let processedText = try await postProcessingService.process(
                rawText: rawText,
                mode: mode,
                language: language,
                contextBundle: contextBundle
            )
            appState.isPostProcessing = false
            overlayController.update(appState: appState)
            return TextNormalizer.normalizeTranscriptionText(processedText)
        } catch {
            appState.isPostProcessing = false
            overlayController.update(appState: appState)

            if AppPreferences.shared.fallbackToRawOnProcessingError {
                let message = error.localizedDescription
                appState.lastError = message
                Logger.transcription.error("Post-processing failed; falling back to raw: \(message)")
                return rawText
            }

            throw error
        }
    }

    private func handleTranscriptionFailure(audioURL: URL, message: String, logPrefix: String) {
        appState?.lastError = message
        Logger.debug(" \(logPrefix): \(message)")
        overlayController.hide()
        try? FileManager.default.removeItem(at: audioURL)
        showErrorAlert(title: "Transcription Failed", message: message)
    }

    private func startScreenClip() async {
        guard let appState else { return }

        do {
            try await visualContextCaptureService.startScreenClip(sourceApp: contextSourceApp)
            appState.isScreenClipRecording = true
            overlayController.update(appState: appState)
            scheduleScreenClipLimit()
        } catch {
            appState.lastError = error.localizedDescription
            Logger.permission.warning("Screen clip context failed: \(error.localizedDescription, privacy: .public)")
            if error as? VisualContextCaptureError == .missingPermission {
                _ = PermissionService.requestScreenRecordingPermission()
            }
            overlayController.update(appState: appState)
        }
    }

    private func stopScreenClipAndAttach() async {
        guard let appState else { return }

        screenClipLimitTask?.cancel()
        screenClipLimitTask = nil

        do {
            let result = try await visualContextCaptureService.stopScreenClip()
            appState.contextBundle.screenClips.append(result.clip)
            appState.contextBundle.visualFrames.append(contentsOf: result.visualFrames)
            appState.lastContextBundle = appState.contextBundle
        } catch {
            appState.lastError = error.localizedDescription
            Logger.permission.warning("Screen clip stop failed: \(error.localizedDescription, privacy: .public)")
        }

        appState.isScreenClipRecording = false
        overlayController.update(appState: appState)
    }

    private func scheduleScreenClipLimit() {
        screenClipLimitTask?.cancel()
        let maxDuration = AppPreferences.shared.maxScreenRecordingDuration
        screenClipLimitTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(maxDuration))
            guard !Task.isCancelled, appState?.isRecording == true, appState?.isScreenClipRecording == true else { return }
            await stopScreenClipAndAttach()
        }
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
