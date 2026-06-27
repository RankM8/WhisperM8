import Foundation
import AppKit

/// Kontext-Bundle-Handling des RecordingCoordinator: paralleles Kontext-
/// Capture nach Aufnahmestart (mit User-Edit-respektierendem Merge) und die
/// Overlay-Edit-Aktionen (Screenshot/Clip hinzufuegen, Pills/Bundle leeren,
/// Anhaenge entfernen). Aus RecordingCoordinator.swift ausgelagert (Phase-2).
extension RecordingCoordinator {
    /// P5: Kontext-Capture laeuft NACH dem Aufnahmestart parallel. Der Merge
    /// am Ende respektiert User-Edits, die waehrenddessen im Overlay passiert
    /// sind (Pill entfernt, Kontext geleert).
    func startContextCapture(
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

    func finishContextCapture(
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
    func waitForContextCapture(timeout: TimeInterval) async {
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
}
