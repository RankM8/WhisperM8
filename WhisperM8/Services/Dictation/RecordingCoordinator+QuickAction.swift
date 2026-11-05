import AppKit

/// Schnellaktion ohne Diktat: verdrahtet den `QuickActionRunner` mit den
/// echten Diensten des Diktats (Markierung lesen, Nacharbeit, Einfügen,
/// Zwischenablage-Verlauf, Overlay, ESC).
extension RecordingCoordinator {
    func makeQuickActionRunner() -> QuickActionRunner {
        let selectedContextService = selectedContextService
        let postProcessingService = postProcessingService
        let pasteService = pasteService
        let replacer = QuickActionReplacer(pasteService: pasteService)
        let historyRecorder = dictationHistoryRecorder
        let busyNotifier = busyHotkeyNotifier

        let environment = QuickActionEnvironment(
            frontmostApp: { NSWorkspace.shared.frontmostApplication },
            // Alle Modi, auch die im Overlay ausgeblendeten: der Kurzbefehl
            // gehört dem Modus, nicht der Modusauswahl beim Diktat.
            modeResolver: { id in OutputModeStore().modes.first { $0.id == id } },
            isPostProcessingAvailable: { AppPreferences.shared.usageProfile.wantsCodexEnrichment },
            captureSelection: { app in await selectedContextService.captureForQuickAction(from: app) },
            // Leere Sprache = „auto“: Die Markierung behält ihre Sprache,
            // unabhängig von der Diktatsprache. Kein Kontext: die Markierung
            // ist hier der Text selbst, nicht Hintergrund.
            rework: { text, mode in
                try await postProcessingService.processRun(rawText: text, mode: mode, language: "", contextBundle: .empty)
            },
            replaceSelection: { text, app in await replacer.replaceSelection(with: text, in: app) },
            copyToClipboard: { pasteService.copyToClipboard($0) },
            recordHistory: { result, original, mode, app in
                historyRecorder(DictationHistoryRecord(text: result, original: original, mode: mode, targetApp: app))
            },
            postNotice: { DictationNotice.post(title: $0, body: $1) },
            busySignal: { busyNotifier(false) },
            cancelEngines: {
                _ = CodexProcessRegistry.shared.cancel(owner: .quickAction)
                _ = GPTBackendRunRegistry.shared.cancel(owner: .quickAction)
            }
        )
        return QuickActionRunner(
            environment: environment,
            presenter: overlayController,
            cancelKey: cleanUpCancelKey,
            isDictationBusy: { [weak self] in self?.isDictationBusy ?? false }
        )
    }

    /// Aufnahme, Verbindungsaufbau, Transkription oder Nacharbeit laufen.
    var isDictationBusy: Bool {
        guard let appState else { return false }
        return appState.isRecording || appState.isTranscribing || appState.isPostProcessing
            || isProcessing || isStartingRecording
    }
}
