import AppKit

private struct PostProcessingRunResult {
    var finalText: String
    var renderedPrompt: String?
    var replyIntent: ReplyIntentKind?
    var visualManifest: VisualManifest?
    var fallbackStatus: TranscriptRunStatus?
    var errorMessage: String?
    var agentProvider: AgentProvider?
    var agentSessionID: String?
    var agentProjectPath: String?
}

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
    private let visualAttachmentDeliveryBuilder: VisualAttachmentDeliveryBuilder
    private let reportStore: TranscriptRunReportStore

    private var recordingStartTime: Date?
    private var isProcessing = false
    private var escKeyMonitor: Any?
    private var contextSourceApp: NSRunningApplication?
    private var screenClipLimitTask: Task<Void, Never>?
    private var clipboardScreenshotTask: Task<Void, Never>?
    private var observedPasteboardChangeCount = NSPasteboard.general.changeCount

    init(
        appState: AppState,
        postProcessingService: PostProcessingService = PostProcessingService(),
        selectedContextService: SelectedContextService = SelectedContextService(),
        visualContextCaptureService: VisualContextCaptureService? = nil,
        reportStore: TranscriptRunReportStore = TranscriptRunReportStore()
    ) {
        self.appState = appState
        self.audioRecorder = AudioRecorder()
        self.overlayController = OverlayController()
        self.pasteService = PasteService()
        self.recordingTimer = RecordingTimer()
        self.postProcessingService = postProcessingService
        self.selectedContextService = selectedContextService
        self.visualContextCaptureService = visualContextCaptureService ?? VisualContextCaptureService()
        self.visualAttachmentDeliveryBuilder = VisualAttachmentDeliveryBuilder()
        self.reportStore = reportStore
    }

    func startRecording() async {
        guard let appState, !appState.isRecording, !appState.isTranscribing, !isProcessing else { return }

        isProcessing = true
        recordingTimer.stop()
        overlayController.hide()
        contextSourceApp = NSWorkspace.shared.frontmostApplication

        do {
            let selectedContext = await selectedContextService.capture(from: contextSourceApp)
            // Auto-Inject des Agent-Chat-Refs nur, wenn WhisperM8 selbst frontmost war
            // beim Recording-Start. Wenn der User in Cursor/VS Code/Browser arbeitet,
            // ist der Chat-Kontext irrelevant — wir wollen ihn nicht „aufzwingen".
            let activeAgentChat: AgentChatContextRef?
            if contextSourceApp?.bundleIdentifier == Bundle.main.bundleIdentifier {
                activeAgentChat = appState.activeAgentChat
            } else {
                activeAgentChat = nil
            }
            let contextBundle = TranscriptContextBundle.from(
                selectedContext: selectedContext,
                sourceApp: contextSourceApp,
                agentChat: activeAgentChat
            )
            try await audioRecorder.startRecording()

            AudioDuckingManager.shared.duck()
            scheduleDuckingReinforcement()

            recordingStartTime = Date()
            appState.isRecording = true
            appState.recordingDuration = 0
            appState.audioLevel = 0
            appState.lastError = nil
            appState.isPostProcessing = false
            appState.postProcessingStatusText = nil
            appState.selectedOutputMode = OutputMode.defaultMode()
            appState.selectedContext = selectedContext
            appState.lastSelectedContext = selectedContext.isEmpty ? nil : selectedContext
            appState.contextBundle = contextBundle
            appState.lastContextBundle = contextBundle.isEmpty ? nil : contextBundle
            appState.isScreenClipRecording = false
            isProcessing = false
            startClipboardScreenshotMonitor()

            overlayController.show(
                appState: appState,
                onCancel: { [weak self] in
                    self?.cancelRecording()
                },
                onCancelPostProcessing: { [weak self] in
                    self?.cancelPostProcessing()
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
                },
                onContextAction: { [weak self] action in
                    guard let self else { return }
                    switch action {
                    case .removeAgentChat:
                        self.removeAgentChatFromContext()
                    case .removeSelectedText:
                        self.removeSelectedTextFromContext()
                    case .removeAttachment(let id):
                        self.removeAttachmentFromContext(id: id)
                    }
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
        importClipboardScreenshotIfNeeded()
        stopClipboardScreenshotMonitor()

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
        appState.postProcessingStatusText = nil
        appState.selectedContext = .empty
        appState.contextBundle = .empty
        appState.isScreenClipRecording = false
        isProcessing = false
        Logger.debug(" stopRecording completed")
    }

    /// Bricht das laufende Codex-Post-Processing ab. Aufgerufen vom Cancel-Button im Overlay,
    /// wenn `isPostProcessing == true`. Der `performCodexRun`-Pfad erkennt das Cancel-Flag und
    /// wirft einen klaren Fehler statt unendlich auf einen toten Stream zu warten.
    func cancelPostProcessing() {
        guard let appState, appState.isPostProcessing else { return }
        _ = CodexProcessRegistry.shared.cancel()
        appState.postProcessingStatusText = "Abgebrochen…"
    }

    func cancelRecording() {
        guard let appState, appState.isRecording else { return }

        recordingTimer.stop()
        removeEscKeyMonitor()
        stopClipboardScreenshotMonitor()
        screenClipLimitTask?.cancel()
        screenClipLimitTask = nil

        let audioURL = audioRecorder.stopRecording()
        if let audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }

        appState.isRecording = false
        appState.audioLevel = 0
        appState.isPostProcessing = false
        appState.postProcessingStatusText = nil
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
        let didImport = importClipboardScreenshotIfNeeded(force: true)
        if !didImport {
            appState.lastError = "No screenshot image found on the clipboard. Use macOS screenshot-to-clipboard, then try again."
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
        // Komplettes Clear inkl. Agent-Chat-Ref — User hat explizit „alles weg" geklickt.
        appState.contextBundle = TranscriptContextBundle.from(
            selectedContext: .empty,
            sourceApp: contextSourceApp,
            agentChat: nil
        )
        appState.selectedContext = .empty
        appState.lastContextBundle = nil
        appState.lastSelectedContext = nil
        overlayController.update(appState: appState)
    }

    // MARK: - Granulare Kontext-Bearbeitung während des Recordings

    /// Entfernt die Agent-Chat-Referenz aus dem laufenden Recording-Bundle.
    /// Andere Kontext-Slots (Text, Screenshots) bleiben erhalten.
    func removeAgentChatFromContext() {
        guard let appState, appState.isRecording else { return }
        guard appState.contextBundle.agentChat != nil else { return }
        appState.contextBundle.agentChat = nil
        overlayController.update(appState: appState)
    }

    /// Entfernt nur den ausgewählten Text aus dem laufenden Recording-Bundle.
    func removeSelectedTextFromContext() {
        guard let appState, appState.isRecording else { return }
        guard !appState.contextBundle.selectedText.isEmpty else { return }
        appState.contextBundle.selectedText = .empty
        appState.selectedContext = .empty
        overlayController.update(appState: appState)
    }

    /// Entfernt einen einzelnen Anhang (Screenshot / Annotation / ScreenClip / VisualFrame)
    /// aus dem laufenden Recording-Bundle und räumt die zugehörige Datei auf.
    func removeAttachmentFromContext(id: UUID) {
        guard let appState, appState.isRecording, !appState.isScreenClipRecording else { return }
        var bundle = appState.contextBundle

        let removed: ContextAttachment?
        if let attachment = bundle.screenshots.first(where: { $0.id == id }) {
            bundle.screenshots.removeAll { $0.id == id }
            removed = attachment
        } else if let attachment = bundle.annotations.first(where: { $0.id == id }) {
            bundle.annotations.removeAll { $0.id == id }
            removed = attachment
        } else if let attachment = bundle.screenClips.first(where: { $0.id == id }) {
            bundle.screenClips.removeAll { $0.id == id }
            removed = attachment
        } else if let attachment = bundle.visualFrames.first(where: { $0.id == id }) {
            bundle.visualFrames.removeAll { $0.id == id }
            removed = attachment
        } else {
            return
        }

        if let removed {
            visualContextCaptureService.cleanup(
                TranscriptContextBundle(
                    screenshots: bundle.screenshots.contains(where: { $0.id == removed.id }) ? [] : (removed.kind == .screenshot ? [removed] : []),
                    annotations: removed.kind == .annotation ? [removed] : [],
                    screenClips: removed.kind == .screenClip ? [removed] : [],
                    visualFrames: removed.kind == .visualFrame ? [removed] : []
                )
            )
        }

        appState.contextBundle = bundle
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

        let postProcessingResult = try await processTranscriptIfNeeded(
            normalizedRawText,
            mode: outputMode,
            language: language,
            contextBundle: contextBundle
        )
        let finalText = postProcessingResult.finalText
        let autoPasteRequested = AppPreferences.shared.isAutoPasteEnabled && outputMode.id != OutputMode.chatID
        var deliveryAttachments: [PasteAttachment] = []
        var deliveryErrors: [String] = []

        if autoPasteRequested {
            do {
                deliveryAttachments = try visualAttachmentDeliveryBuilder.build(
                    contextBundle: contextBundle,
                    mode: outputMode
                )
            } catch {
                let message = "Could not prepare visual attachments for paste: \(error.localizedDescription)"
                Logger.paste.error("\(message, privacy: .public)")
                deliveryErrors.append(message)
            }
        }

        pasteService.copyToClipboard(finalText)
        appState.lastFinalTranscription = finalText
        appState.lastTranscription = finalText

        var pasteResult = PasteDeliveryResult.notRequested

        if autoPasteRequested {
            let previousApp = overlayController.getPreviousApp()
            overlayController.hide()
            pasteResult = await pasteService.pastePayloadToActiveApp(
                PastePayload(
                    text: finalText,
                    attachments: deliveryAttachments,
                    restoreTextToClipboardAfterPaste: true
                ),
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

        deliveryErrors.append(contentsOf: pasteResult.errors)
        if appState.lastError == nil, let firstError = deliveryErrors.first {
            appState.lastError = firstError
        }

        saveRunReport(
            status: postProcessingResult.errorMessage == nil ? .succeeded : (postProcessingResult.fallbackStatus ?? .rawFallback),
            errorMessage: postProcessingResult.errorMessage,
            outputMode: outputMode,
            provider: provider,
            model: model,
            language: language,
            audioDuration: audioDuration,
            contextBundle: contextBundle,
            renderedPrompt: postProcessingResult.renderedPrompt,
            replyIntent: postProcessingResult.replyIntent,
            visualManifest: postProcessingResult.visualManifest,
            rawText: normalizedRawText,
            finalText: finalText,
            copiedToClipboard: true,
            autoPasteRequested: autoPasteRequested,
            autoPasteTextRequested: autoPasteRequested,
            autoPasteAttachmentsRequested: autoPasteRequested && !deliveryAttachments.isEmpty,
            pastedAttachmentCount: pasteResult.pastedAttachments.count,
            pasteErrors: deliveryErrors,
            deliveryAttachmentLabels: deliveryAttachments.map(\.label),
            agentProvider: postProcessingResult.agentProvider,
            agentSessionID: postProcessingResult.agentSessionID,
            agentProjectPath: postProcessingResult.agentProjectPath
        )

        try? FileManager.default.removeItem(at: audioURL)
        visualContextCaptureService.cleanup(contextBundle)
    }

    private func processTranscriptIfNeeded(
        _ rawText: String,
        mode: OutputMode,
        language: String,
        contextBundle: TranscriptContextBundle
    ) async throws -> PostProcessingRunResult {
        guard let appState else {
            return PostProcessingRunResult(finalText: rawText)
        }

        guard mode.usesPostProcessing else {
            return PostProcessingRunResult(finalText: rawText)
        }

        let allowedContextBundle = postProcessingService.allowedContextBundle(for: mode, capturedContext: contextBundle)
        let promptPackage = postProcessingService.promptPackage(
            rawText: rawText,
            mode: mode,
            language: language,
            contextBundle: allowedContextBundle
        )
        let renderedPrompt = promptPackage?.prompt

        appState.isTranscribing = false
        appState.isPostProcessing = true
        appState.postProcessingStatusText = promptPackage?.intent.overlayStatusText
        overlayController.update(appState: appState)

        do {
            if mode.id == OutputMode.chatID, let promptPackage {
                let visualInput = CodexVisualInputSelection(contextBundle: contextBundle)
                let result = try AgentChatLaunchService().openCodexChat(
                    title: chatTitle(from: rawText),
                    prompt: promptPackage.prompt,
                    imagePaths: visualInput.imageURLs.map(\.path)
                )
                appState.isPostProcessing = false
                appState.postProcessingStatusText = nil
                overlayController.update(appState: appState)
                return PostProcessingRunResult(
                    finalText: "Opened Codex chat: \(result.session.title)",
                    renderedPrompt: renderedPrompt,
                    replyIntent: promptPackage.intent,
                    visualManifest: promptPackage.visualManifest,
                    agentProvider: .codex,
                    agentSessionID: result.session.externalSessionID ?? result.session.id.uuidString,
                    agentProjectPath: result.project.path
                )
            }

            let processedText = try await postProcessingService.process(
                rawText: rawText,
                mode: mode,
                language: language,
                contextBundle: contextBundle
            )
            let agentSession = mode.id == OutputMode.taskID ? latestTaskAgentSession() : nil
            appState.isPostProcessing = false
            appState.postProcessingStatusText = nil
            overlayController.update(appState: appState)
            return PostProcessingRunResult(
                finalText: TextNormalizer.normalizeTranscriptionText(processedText),
                renderedPrompt: renderedPrompt,
                replyIntent: promptPackage?.intent,
                visualManifest: promptPackage?.visualManifest,
                agentProvider: agentSession?.provider,
                agentSessionID: agentSession?.externalSessionID,
                agentProjectPath: agentSession?.projectPath
            )
        } catch {
            appState.isPostProcessing = false
            appState.postProcessingStatusText = nil
            overlayController.update(appState: appState)

            if case PostProcessingError.userCancelled = error {
                Logger.transcription.info("Post-processing cancelled by user; using raw transcript without surfacing an error")
                return PostProcessingRunResult(finalText: rawText)
            }

            if AppPreferences.shared.fallbackToRawOnProcessingError {
                let message = error.localizedDescription
                appState.lastError = message
                Logger.transcription.error("Post-processing failed; falling back to raw: \(message)")
                let fallback = cautiousFallbackText(
                    rawText: rawText,
                    mode: mode,
                    intent: promptPackage?.intent
                )
                return PostProcessingRunResult(
                    finalText: fallback.text,
                    renderedPrompt: renderedPrompt,
                    replyIntent: promptPackage?.intent,
                    visualManifest: promptPackage?.visualManifest,
                    fallbackStatus: fallback.status,
                    errorMessage: message
                )
            }

            throw error
        }
    }

    private func chatTitle(from rawText: String) -> String {
        let trimmed = rawText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Voice Chat" }
        return String(trimmed.prefix(52))
    }

    private func latestTaskAgentSession() -> (provider: AgentProvider, externalSessionID: String?, projectPath: String?)? {
        let projectPath = AppPreferences.shared.agentDefaultProjectPath
        do {
            let store = AgentSessionStore()
            let indexedSessions = CodexSessionIndexer().indexedSessions(limit: 20)
            try store.mergeIndexedSessions(indexedSessions)
            let latest = indexedSessions.first { URL(fileURLWithPath: $0.cwd).standardizedFileURL.path == URL(fileURLWithPath: projectPath).standardizedFileURL.path }
            return latest.map { ($0.provider, $0.externalSessionID, $0.cwd) }
        } catch {
            Logger.debug("Failed to sync task agent session: \(error.localizedDescription)")
            return nil
        }
    }

    private func cautiousFallbackText(
        rawText: String,
        mode: OutputMode,
        intent: ReplyIntentKind?
    ) -> (text: String, status: TranscriptRunStatus) {
        guard intent == .agenticReply || intent == .contextAnswer else {
            return (rawText, .rawFallback)
        }

        switch mode.id {
        case OutputMode.slackID:
            return ("Ich prüfe das kurz sauber und melde mich direkt mit einer konkreten Antwort.", .cautiousFallback)
        case OutputMode.whatsappID:
            return ("Ich schau mir das kurz in Ruhe an und melde mich gleich mit einer konkreten Antwort.", .cautiousFallback)
        case OutputMode.emailID:
            return ("Ich prüfe das kurz sorgfältig und melde mich anschließend mit einer konkreten Antwort.", .cautiousFallback)
        default:
            return (rawText, .rawFallback)
        }
    }

    private func saveRunReport(
        status: TranscriptRunStatus,
        errorMessage: String?,
        outputMode: OutputMode,
        provider: TranscriptionProvider,
        model: TranscriptionModel,
        language: String,
        audioDuration: TimeInterval,
        contextBundle: TranscriptContextBundle,
        renderedPrompt: String?,
        replyIntent: ReplyIntentKind?,
        visualManifest: VisualManifest?,
        rawText: String?,
        finalText: String?,
        copiedToClipboard: Bool,
        autoPasteRequested: Bool,
        autoPasteTextRequested: Bool = false,
        autoPasteAttachmentsRequested: Bool = false,
        pastedAttachmentCount: Int = 0,
        pasteErrors: [String] = [],
        deliveryAttachmentLabels: [String] = [],
        agentProvider: AgentProvider? = nil,
        agentSessionID: String? = nil,
        agentProjectPath: String? = nil
    ) {
        let draft = TranscriptRunReportDraft(
            sourceAppName: contextSourceApp?.localizedName,
            sourceBundleIdentifier: contextSourceApp?.bundleIdentifier,
            status: status,
            errorMessage: errorMessage,
            mode: outputMode,
            provider: provider,
            transcriptionModel: model,
            language: language,
            audioDuration: audioDuration,
            contextBundle: contextBundle,
            renderedPrompt: renderedPrompt,
            replyIntent: replyIntent,
            visualManifest: visualManifest,
            rawTranscript: rawText,
            finalTranscript: finalText,
            copiedToClipboard: copiedToClipboard,
            autoPasteRequested: autoPasteRequested,
            autoPasteTextRequested: autoPasteTextRequested,
            autoPasteAttachmentsRequested: autoPasteAttachmentsRequested,
            pastedAttachmentCount: pastedAttachmentCount,
            pasteErrors: pasteErrors,
            deliveryAttachmentLabels: deliveryAttachmentLabels,
            agentProvider: agentProvider,
            agentSessionID: agentSessionID,
            agentProjectPath: agentProjectPath
        )

        do {
            appState?.lastTranscriptRunReport = try reportStore.save(draft)
        } catch {
            Logger.debug("Failed to save transcript report: \(error.localizedDescription)")
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

    private func startClipboardScreenshotMonitor() {
        stopClipboardScreenshotMonitor()
        observedPasteboardChangeCount = NSPasteboard.general.changeCount

        clipboardScreenshotTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.importClipboardScreenshotIfNeeded()
            }
        }
    }

    private func stopClipboardScreenshotMonitor() {
        clipboardScreenshotTask?.cancel()
        clipboardScreenshotTask = nil
    }

    @discardableResult
    private func importClipboardScreenshotIfNeeded(force: Bool = false) -> Bool {
        guard let appState, appState.isRecording, !appState.isTranscribing, !appState.isPostProcessing else { return false }
        guard AppPreferences.shared.isVisualContextCaptureEnabled else { return false }

        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard force || changeCount != observedPasteboardChangeCount else { return false }
        observedPasteboardChangeCount = changeCount

        guard appState.contextBundle.screenshots.count < AppPreferences.shared.maxScreenshotsPerRecording else {
            appState.lastError = "Maximum screenshots for this recording reached."
            overlayController.update(appState: appState)
            return false
        }

        do {
            guard let screenshot = try visualContextCaptureService.captureClipboardScreenshot(
                from: pasteboard,
                changeCount: changeCount,
                sourceApp: contextSourceApp
            ) else {
                return false
            }

            appState.contextBundle.screenshots.append(screenshot)
            appState.lastContextBundle = appState.contextBundle
            appState.lastError = nil
            overlayController.update(appState: appState)
            return true
        } catch {
            appState.lastError = error.localizedDescription
            Logger.permission.warning("Clipboard screenshot context failed: \(error.localizedDescription, privacy: .public)")
            overlayController.update(appState: appState)
            return false
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
