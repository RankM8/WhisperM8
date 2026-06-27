import AppKit

struct PostProcessingRunResult {
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

/// Eingefrorener Zustand eines fehlgeschlagenen Transkriptions-Laufs.
/// Hält alles fest, was ein Retry braucht, um exakt denselben Lauf
/// (gleicher Output-Mode, gleicher Kontext) erneut zu starten.
struct PendingTranscriptionRetry {
    var recording: FailedRecording
    var audioDuration: TimeInterval
    var outputMode: OutputMode
    var contextBundle: TranscriptContextBundle
}

@MainActor
final class RecordingCoordinator {
    weak var appState: AppState?
    let audioRecorder: AudioRecorder
    let overlayController: OverlayController
    let pasteService: PasteService
    let recordingTimer: RecordingTimer
    let postProcessingService: PostProcessingService
    let selectedContextService: SelectedContextService
    let visualContextCaptureService: VisualContextCaptureService
    let visualAttachmentDeliveryBuilder: VisualAttachmentDeliveryBuilder
    let reportStore: TranscriptRunReportStore

    var recordingStartTime: Date?
    private var isProcessing = false
    var escKeyMonitor: Any?
    var contextSourceApp: NSRunningApplication?
    var screenClipLimitTask: Task<Void, Never>?
    var clipboardScreenshotTask: Task<Void, Never>?
    var observedPasteboardChangeCount = NSPasteboard.general.changeCount
    /// P5: paralleler Kontext-Capture-Task (Selected-Text + Agent-Chat-Tail),
    /// laeuft NACH dem Aufnahmestart und reicht den Kontext nach.
    var contextCaptureTask: Task<Void, Never>?
    /// `true`, wenn der User waehrend des laufenden Captures den Kontext im
    /// Overlay geleert hat — der Merge darf dann nichts nachreichen.
    var userClearedContextDuringCapture = false
    let failedRecordingsStore: FailedRecordingsStore
    /// Laufender Transkriptions-Call als cancelbarer Task. `cancelTranscription()`
    /// (Overlay-Button/ESC) cancelt ihn; URLSession bricht den Upload dann ab.
    var transcriptionTask: Task<Void, Error>?
    /// `true`, sobald die Transkriptions-Response eingetroffen ist und die
    /// Delivery läuft (Clipboard/Auto-Paste). Ein Cancel darf dann nichts
    /// mehr abbrechen — ein gesetztes Cancel-Flag würde die `Task.sleep`-
    /// Delays im PasteService kollabieren lassen und das CGEvent-Timing
    /// zerstören.
    var isDeliveringTranscription = false
    /// Letzter fehlgeschlagener Lauf — Grundlage für "Erneut versuchen".
    var pendingRetry: PendingTranscriptionRetry?

    // Phase-3-Test-Seams: Diktat-Abhängigkeiten als Resolver-Closures.
    // Defaults = bisherige Statics → Produktionsverhalten unverändert; Tests
    // injizieren Fakes (kein Keychain/Settings/Netzwerk im Test).
    let providerResolver: () -> TranscriptionProvider
    let modelResolver: () -> TranscriptionModel
    let apiKeyResolver: (TranscriptionProvider) -> String?
    let transcriberFactory: (TranscriptionProvider, TranscriptionModel, String) -> TranscriptionServiceProtocol
    let agentChatLauncherFactory: () -> AgentChatLaunchService

    init(
        appState: AppState,
        postProcessingService: PostProcessingService = PostProcessingService(),
        selectedContextService: SelectedContextService = SelectedContextService(),
        visualContextCaptureService: VisualContextCaptureService? = nil,
        reportStore: TranscriptRunReportStore = TranscriptRunReportStore(),
        failedRecordingsStore: FailedRecordingsStore = FailedRecordingsStore(),
        providerResolver: @escaping () -> TranscriptionProvider = {
            TranscriptionSettings.migrateIfNeeded()
            return TranscriptionSettings.loadProvider()
        },
        modelResolver: @escaping () -> TranscriptionModel = { TranscriptionSettings.loadModel() },
        apiKeyResolver: @escaping (TranscriptionProvider) -> String? = { KeychainManager.load(key: $0.keychainKey) },
        transcriberFactory: @escaping (TranscriptionProvider, TranscriptionModel, String) -> TranscriptionServiceProtocol = { provider, model, apiKey in
            provider.createService(apiKey: apiKey, model: model)
        },
        agentChatLauncherFactory: @escaping () -> AgentChatLaunchService = { AgentChatLaunchService() }
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
        self.failedRecordingsStore = failedRecordingsStore
        self.providerResolver = providerResolver
        self.modelResolver = modelResolver
        self.apiKeyResolver = apiKeyResolver
        self.transcriberFactory = transcriberFactory
        self.agentChatLauncherFactory = agentChatLauncherFactory
    }

    func startRecording() async {
        guard let appState, !appState.isRecording, !appState.isTranscribing, !isProcessing else { return }
        // Budget 400 ms für Hotkey → Aufnahme läuft. Beim allerersten Start
        // (Mikrofon-Permission-Dialog) reisst das Budget bewusst — genau das
        // macht die Violation-Logzeile sichtbar.
        let startToken = PerfBudgets.recordingStart.begin()
        defer { PerfBudgets.recordingStart.end(startToken) }

        let hotkeyAt = Date()
        isProcessing = true
        recordingTimer.stop()
        overlayController.hide()
        contextSourceApp = NSWorkspace.shared.frontmostApplication

        // Auto-Inject des Agent-Chat-Refs nur, wenn WhisperM8 selbst frontmost war
        // beim Recording-Start. Wenn der User in Cursor/VS Code/Browser arbeitet,
        // ist der Chat-Kontext irrelevant — wir wollen ihn nicht „aufzwingen".
        let activeAgentChat: AgentChatContextRef?
        if contextSourceApp?.bundleIdentifier == Bundle.main.bundleIdentifier {
            activeAgentChat = appState.activeAgentChat
        } else {
            activeAgentChat = nil
        }

        do {
            // P5: Aufnahme SOFORT starten. Selected-Text-Capture (~240 ms
            // Clipboard-Sleeps im Fallback) und Agent-Chat-Tail (JSONL-Read)
            // laufen danach als paralleler Task und werden nachgereicht —
            // vorher lagen sie komplett VOR dem Recorder-Start und haben die
            // ersten Silben des Diktats gekostet.
            //
            // Pre-Switch-Capture: Volume MUSS gelesen werden BEVOR der AVAudioEngine
            // startet, sonst hat macOS bei Bluetooth-Devices bereits den A2DP→HFP-
            // Profile-Switch angestossen und wir merken uns einen falschen "Original"-Wert.
            // Routing-Listener im Manager faengt den Switch auf das HFP-Profil
            // (eigene DeviceID auf manchen Macs) automatisch ab und duckt es ebenfalls.
            try await PerfBudgets.engineStart.withInterval {
                AudioDuckingManager.shared.beginCapture()
                try await audioRecorder.startRecording()
            }
        } catch {
            appState.lastError = error.localizedDescription
            AudioDuckingManager.shared.endCaptureImmediate()
            isProcessing = false
            return
        }

        Logger.transcription.info(
            "recording_start_latency ms=\(Int(Date().timeIntervalSince(hotkeyAt) * 1000), privacy: .public)"
        )

        recordingStartTime = Date()
        appState.isRecording = true
        appState.recordingDuration = 0
        appState.audioLevel = 0
        appState.lastError = nil
        appState.isPostProcessing = false
        appState.postProcessingStatusText = nil
        appState.selectedOutputMode = OutputMode.defaultMode()
        appState.selectedContext = .empty
        appState.lastSelectedContext = nil
        // Start-Bundle enthaelt nur das synchron Verfuegbare (sourceApp +
        // Agent-Chat-Ref); selectedText und Tail reicht der Capture-Task nach.
        appState.contextBundle = TranscriptContextBundle.from(
            selectedContext: .empty,
            sourceApp: contextSourceApp,
            agentChat: activeAgentChat
        )
        appState.lastContextBundle = nil
        appState.isScreenClipRecording = false
        userClearedContextDuringCapture = false
        isProcessing = false

        presentOverlay(appState: appState)
        setupEscKeyMonitor()
        startDurationTimer()

        startContextCapture(
            appState: appState,
            sourceApp: contextSourceApp,
            agentChat: activeAgentChat
        )
    }

    /// Zeigt das Recording-Overlay mit dem vollständigen Callback-Wiring.
    /// Geteilt zwischen `startRecording()` und `retryPendingTranscription()`.
    private func presentOverlay(appState: AppState) {
        overlayController.show(
            appState: appState,
            onCancel: { [weak self] in
                self?.cancelRecording()
            },
            onCancelTranscription: { [weak self] in
                self?.cancelTranscription()
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
    }

    func stopRecording() async {
        guard let appState, appState.isRecording, !appState.isTranscribing, !isProcessing else {
            if let appState {
                Logger.debug("stopRecording guard failed: isRecording=\(appState.isRecording), isTranscribing=\(appState.isTranscribing), isProcessing=\(isProcessing)")
            }
            return
        }

        // Misst Entry → Start der Transkription (Budget 300 ms). Explizites
        // End vor runCancelableTranscription; das Safety-defer fängt die
        // Early-Return-Pfade (zu kurze Aufnahme, fehlende Audio-Datei) —
        // `end` ist idempotent.
        let stopToken = PerfBudgets.recordingStop.begin()
        defer { PerfBudgets.recordingStop.end(stopToken) }

        if let recordingStartTime {
            let elapsed = Date().timeIntervalSince(recordingStartTime)
            if elapsed < 0.3 {
                // WICHTIG, nicht "verbessern": Der Hotkey ist KeyDown=Start /
                // KeyUp=Stop verdrahtet. Ein kurzer TAP feuert Start und
                // ~100 ms spaeter diesen Stop — der fruehe Stop MUSS ignoriert
                // werden (Aufnahme laeuft weiter), sonst ist Tap-Diktieren
                // unmoeglich: Genau das hat der "Doppel-Tap verwerfen"-Ansatz
                // (cancelRecording hier) am 10.06. kaputt gemacht — Overlay
                // erschien kurz und verschwand sofort wieder. Tap-Semantik:
                // Tap startet, naechster Tap (KeyUp nach >0,3 s) stoppt.
                Logger.debug(" Stop within \(elapsed)s ignored (tap-to-toggle)")
                return
            }
        }

        isProcessing = true
        if appState.isScreenClipRecording {
            await stopScreenClipAndAttach()
        }
        // VOR dem finalen Clipboard-Sweep auf den Capture-Task warten —
        // sonst importiert der Sweep dessen Cmd+C-/Restore-Pasteboard-Bumps
        // als User-Kontext (und kurze Diktate verloeren ihren Kontext).
        await waitForContextCapture(timeout: 1.0)
        observeClipboardChange()
        stopClipboardScreenshotMonitor()

        let audioDuration = appState.recordingDuration
        let frozenOutputMode = appState.selectedOutputMode
        let frozenContextBundle = appState.contextBundle
        Logger.debug(" Stopping recording. Duration: \(String(format: "%.1f", audioDuration))s")
        // Letzte Wahrheit vor dem Transcription-Call: was geht jetzt wirklich
        // raus? Inkludiert User-Edits aus dem Overlay (z. B. Pill entfernt).
        Logger.transcription.info(
            "recording_context_committed agentChatPresent=\(frozenContextBundle.agentChat != nil, privacy: .public) provider=\(frozenContextBundle.agentChat?.provider.rawValue ?? "none", privacy: .public) project=\(frozenContextBundle.agentChat?.projectName ?? "none", privacy: .public) chatTitle=\(frozenContextBundle.agentChat?.title ?? "none", privacy: .public) externalID=\(frozenContextBundle.agentChat?.externalSessionID ?? "none", privacy: .public) tailChars=\(frozenContextBundle.agentChatTail?.count ?? 0, privacy: .public) selectedTextChars=\(frozenContextBundle.selectedText.text.count, privacy: .public) attachments=\(frozenContextBundle.attachmentCount, privacy: .public)"
        )

        recordingTimer.stop()
        // ESC-Monitor bleibt bewusst aktiv: Er bricht jetzt auch die
        // Transcribing-Phase ab (siehe `setupEscKeyMonitor`). Entfernt wird
        // er erst, wenn der Transkriptions-Task durch ist.

        let audioURL = audioRecorder.stopRecording()
        appState.isRecording = false
        appState.audioLevel = 0
        recordingStartTime = nil

        Logger.debug("[RecordingCoordinator] Calling AudioDuckingManager.endCapture()")
        AudioDuckingManager.shared.endCapture()

        guard let audioURL else {
            Logger.debug(" ERROR: No audio URL returned from recorder")
            removeEscKeyMonitor()
            overlayController.hide()
            isProcessing = false
            showErrorAlert(title: "Recording Error", message: "No audio file was created.")
            return
        }

        logAudioFileAttributes(audioURL)

        appState.isTranscribing = true
        appState.lastOutputMode = frozenOutputMode
        overlayController.update(appState: appState)

        PerfBudgets.recordingStop.end(stopToken)
        await runCancelableTranscription(
            audioURL: audioURL,
            audioDuration: audioDuration,
            outputMode: frozenOutputMode,
            contextBundle: frozenContextBundle
        )
        removeEscKeyMonitor()

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
    /// wenn `isPostProcessing == true`. Der `performCodexRun`-Pfad erkennt das Cancel-Flag,
    /// terminiert den Codex-Prozess und der Coordinator fällt kontrolliert auf Raw zurück.
    func cancelPostProcessing() {
        guard let appState, appState.isPostProcessing else { return }
        _ = CodexProcessRegistry.shared.cancel()
        appState.postProcessingStatusText = "Abgebrochen…"
    }

    /// Bricht den laufenden Transkriptions-Upload ab (Overlay-Button oder ESC
    /// während "Transcribing…"). Die Aufnahme geht dabei nicht verloren —
    /// der Abbruch-Pfad sichert sie in den FailedRecordings-Ordner.
    /// Sobald die Response da ist (`isDeliveringTranscription`), ist der
    /// Abbruch ein No-Op: Die Delivery darf nicht mehr gestört werden.
    func cancelTranscription() {
        guard let appState, appState.isTranscribing, !isDeliveringTranscription else { return }
        Logger.transcription.info("Cancelling in-flight transcription")
        transcriptionTask?.cancel()
    }

    /// Führt `transcribeAndDeliver` als cancelbaren Task aus und übersetzt das
    /// Ergebnis in Erfolgs-/Fehler-/Abbruch-Pfade. Die Aufnahme wird bei JEDEM
    /// Misserfolg aufbewahrt — gelöscht wird sie nur im Erfolgsfall (durch
    /// `transcribeAndDeliver` selbst) oder später durch die Aufräum-Policy
    /// des Stores.
    private func runCancelableTranscription(
        audioURL: URL,
        audioDuration: TimeInterval,
        outputMode: OutputMode,
        contextBundle: TranscriptContextBundle
    ) async {
        isDeliveringTranscription = false
        let task = Task {
            try await self.transcribeAndDeliver(
                audioURL: audioURL,
                audioDuration: audioDuration,
                outputMode: outputMode,
                contextBundle: contextBundle
            )
        }
        transcriptionTask = task

        let result = await task.result
        // Task-Slot VOR den Fehler-Handlern freigeben: Solange der modale
        // Fehler-Alert offen ist, darf der ESC-Monitor ESC nicht mehr
        // schlucken (sein Guard prüft `transcriptionTask != nil`).
        transcriptionTask = nil

        switch result {
        case .success:
            // Erfolg: War das ein Retry aus dem Store, den Sidecar mit
            // abräumen (die Audio-Datei hat transcribeAndDeliver bereits
            // gelöscht).
            if let pending = pendingRetry, pending.recording.audioURL == audioURL {
                failedRecordingsStore.remove(pending.recording)
                pendingRetry = nil
            }
        case .failure(is CancellationError):
            handleTranscriptionCancelled(audioURL: audioURL, audioDuration: audioDuration, outputMode: outputMode, contextBundle: contextBundle)
        case .failure(let urlError as URLError) where urlError.code == .cancelled:
            handleTranscriptionCancelled(audioURL: audioURL, audioDuration: audioDuration, outputMode: outputMode, contextBundle: contextBundle)
        case .failure(let urlError as URLError):
            handleTranscriptionFailure(audioURL: audioURL, audioDuration: audioDuration, outputMode: outputMode, contextBundle: contextBundle, message: networkErrorMessage(for: urlError), logPrefix: "URL ERROR: \(urlError.code.rawValue)")
        case .failure(let transcriptionError as TranscriptionError):
            handleTranscriptionFailure(audioURL: audioURL, audioDuration: audioDuration, outputMode: outputMode, contextBundle: contextBundle, message: transcriptionError.errorDescription ?? "Unknown error", logPrefix: "TRANSCRIPTION ERROR")
        case .failure(let error):
            handleTranscriptionFailure(audioURL: audioURL, audioDuration: audioDuration, outputMode: outputMode, contextBundle: contextBundle, message: error.localizedDescription, logPrefix: "UNKNOWN ERROR: \(type(of: error))")
        }
    }

    /// Startet den letzten fehlgeschlagenen Lauf erneut — mit derselben
    /// gesicherten Aufnahme, demselben Output-Mode und demselben
    /// Kontext-Bundle. Ausgelöst vom "Erneut versuchen"-Button des
    /// Fehler-Alerts.
    func retryPendingTranscription() async {
        guard let appState, let pending = pendingRetry else { return }
        guard !appState.isRecording, !appState.isTranscribing, !isProcessing else { return }

        isProcessing = true
        appState.lastError = nil
        appState.isTranscribing = true
        appState.lastOutputMode = pending.outputMode
        presentOverlay(appState: appState)
        overlayController.update(appState: appState)
        setupEscKeyMonitor()

        await runCancelableTranscription(
            audioURL: pending.recording.audioURL,
            audioDuration: pending.audioDuration,
            outputMode: pending.outputMode,
            contextBundle: pending.contextBundle
        )
        removeEscKeyMonitor()

        appState.isTranscribing = false
        appState.isPostProcessing = false
        appState.postProcessingStatusText = nil
        isProcessing = false
    }

    func cancelRecording() {
        guard let appState, appState.isRecording else { return }

        recordingTimer.stop()
        removeEscKeyMonitor()
        stopClipboardScreenshotMonitor()
        screenClipLimitTask?.cancel()
        screenClipLimitTask = nil
        contextCaptureTask?.cancel()
        contextCaptureTask = nil

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
        AudioDuckingManager.shared.endCapture()
        overlayController.hide()

        Logger.paste.info("Recording cancelled by user")
    }

    var hasAccessibilityPermission: Bool {
        PermissionService.hasAccessibilityPermission
    }

    func requestAccessibilityPermission() {
        PermissionService.requestAccessibilityPermission()
    }

}
