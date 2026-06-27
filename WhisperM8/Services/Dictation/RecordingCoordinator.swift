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
private struct PendingTranscriptionRetry {
    var recording: FailedRecording
    var audioDuration: TimeInterval
    var outputMode: OutputMode
    var contextBundle: TranscriptContextBundle
}

@MainActor
final class RecordingCoordinator {
    weak var appState: AppState?
    private let audioRecorder: AudioRecorder
    let overlayController: OverlayController
    let pasteService: PasteService
    private let recordingTimer: RecordingTimer
    let postProcessingService: PostProcessingService
    private let selectedContextService: SelectedContextService
    let visualContextCaptureService: VisualContextCaptureService
    let visualAttachmentDeliveryBuilder: VisualAttachmentDeliveryBuilder
    let reportStore: TranscriptRunReportStore

    private var recordingStartTime: Date?
    private var isProcessing = false
    private var escKeyMonitor: Any?
    var contextSourceApp: NSRunningApplication?
    var screenClipLimitTask: Task<Void, Never>?
    var clipboardScreenshotTask: Task<Void, Never>?
    var observedPasteboardChangeCount = NSPasteboard.general.changeCount
    /// P5: paralleler Kontext-Capture-Task (Selected-Text + Agent-Chat-Tail),
    /// laeuft NACH dem Aufnahmestart und reicht den Kontext nach.
    private var contextCaptureTask: Task<Void, Never>?
    /// `true`, wenn der User waehrend des laufenden Captures den Kontext im
    /// Overlay geleert hat — der Merge darf dann nichts nachreichen.
    private var userClearedContextDuringCapture = false
    private let failedRecordingsStore: FailedRecordingsStore
    /// Laufender Transkriptions-Call als cancelbarer Task. `cancelTranscription()`
    /// (Overlay-Button/ESC) cancelt ihn; URLSession bricht den Upload dann ab.
    private var transcriptionTask: Task<Void, Error>?
    /// `true`, sobald die Transkriptions-Response eingetroffen ist und die
    /// Delivery läuft (Clipboard/Auto-Paste). Ein Cancel darf dann nichts
    /// mehr abbrechen — ein gesetztes Cancel-Flag würde die `Task.sleep`-
    /// Delays im PasteService kollabieren lassen und das CGEvent-Timing
    /// zerstören.
    var isDeliveringTranscription = false
    /// Letzter fehlgeschlagener Lauf — Grundlage für "Erneut versuchen".
    private var pendingRetry: PendingTranscriptionRetry?

    init(
        appState: AppState,
        postProcessingService: PostProcessingService = PostProcessingService(),
        selectedContextService: SelectedContextService = SelectedContextService(),
        visualContextCaptureService: VisualContextCaptureService? = nil,
        reportStore: TranscriptRunReportStore = TranscriptRunReportStore(),
        failedRecordingsStore: FailedRecordingsStore = FailedRecordingsStore()
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

    /// P5: Kontext-Capture laeuft NACH dem Aufnahmestart parallel. Der Merge
    /// am Ende respektiert User-Edits, die waehrenddessen im Overlay passiert
    /// sind (Pill entfernt, Kontext geleert).
    private func startContextCapture(
        appState: AppState,
        sourceApp: NSRunningApplication?,
        agentChat: AgentChatContextRef?
    ) {
        contextCaptureTask?.cancel()
        contextCaptureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let selectedContext = await PerfBudgets.contextCapture.withInterval {
                await self.selectedContextService.capture(from: sourceApp)
            }
            // JSONL-Tail OFF-MAIN lesen — Transcript-Dateien koennen >50 MB
            // gross sein; der alte Kommentar "blockiert die UI nicht" war
            // falsch, extract ist eine synchrone File-I/O-Funktion.
            let tail: String?
            if let agentChat {
                tail = await Task.detached(priority: .userInitiated) {
                    PerfBudgets.chatTail.withInterval {
                        AgentChatTailExtractor.extract(for: agentChat)
                    }
                }.value
            } else {
                tail = nil
            }

            guard !Task.isCancelled else { return }
            self.finishContextCapture(
                appState: appState,
                selectedContext: selectedContext,
                tail: tail
            )
            self.contextCaptureTask = nil
        }
    }

    private func finishContextCapture(
        appState: AppState,
        selectedContext: SelectedContext,
        tail: String?
    ) {
        guard appState.isRecording else { return }

        let merged = ContextCaptureMerge.apply(
            captured: selectedContext,
            tail: tail,
            into: appState.contextBundle,
            userClearedSelectedText: userClearedContextDuringCapture
        )
        appState.contextBundle = merged
        appState.selectedContext = merged.selectedText
        appState.lastContextBundle = merged.isEmpty ? nil : merged
        appState.lastSelectedContext = merged.selectedText.isEmpty ? nil : merged.selectedText

        // Diagnostik: explizit loggen, was wir als Chat-Kontext gegriffen
        // haben — Quelle der Wahrheit fuer User-Reports "warum hatte der
        // Prompt nicht den erwarteten Kontext".
        Logger.transcription.info(
            "recording_context_snapshot agentChatPresent=\(merged.agentChat != nil, privacy: .public) provider=\(merged.agentChat?.provider.rawValue ?? "none", privacy: .public) project=\(merged.agentChat?.projectName ?? "none", privacy: .public) externalID=\(merged.agentChat?.externalSessionID ?? "none", privacy: .public) tailChars=\(merged.agentChatTail?.count ?? 0, privacy: .public) selectedTextChars=\(merged.selectedText.text.count, privacy: .public) sourceApp=\(self.contextSourceApp?.bundleIdentifier ?? "unknown", privacy: .public)"
        )
        overlayController.update(appState: appState)

        // Pasteboard-Resync: Das Capture erzeugt im Clipboard-Fallback eigene
        // changeCount-Bumps (Cmd+C + Snapshot-Restore). Resync, damit der
        // 500-ms-Monitor sie nicht als User-Kopie importiert. Bekannte
        // Restluecke (existierte auch vorher): eine echte User-Kopie im
        // Capture-Fenster wird mit verschluckt.
        observedPasteboardChangeCount = NSPasteboard.general.changeCount
        startClipboardScreenshotMonitor()
    }

    /// Stop wartet (begrenzt) auf den parallelen Capture-Task, damit kurze
    /// Diktate ihren Kontext trotzdem bekommen. Muss VOR dem finalen
    /// Clipboard-Sweep laufen — sonst importiert der Sweep den temporaeren
    /// Cmd+C-/Restore-Inhalt des Captures als User-Kontext.
    private func waitForContextCapture(timeout: TimeInterval) async {
        guard contextCaptureTask != nil else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while contextCaptureTask != nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        // Timeout: Capture haengt (z. B. JSONL auf langsamem Volume) — der
        // Lauf geht ohne den nachgereichten Kontext raus.
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
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
        userClearedContextDuringCapture = true
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
        userClearedContextDuringCapture = true
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

    /// Misserfolg-Pfad: Aufnahme aufbewahren (nie löschen!) und Retry anbieten.
    /// Vor diesem Fix wurde die M4A hier sofort gelöscht — ein Netz-Timeout
    /// nach einem langen Diktat war damit unwiederbringlicher Datenverlust.
    private func handleTranscriptionFailure(
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
    private func handleTranscriptionCancelled(
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
    private func preserveRecording(
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
    private func showTranscriptionFailureAlert(message: String, canRetry: Bool) -> Bool {
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
