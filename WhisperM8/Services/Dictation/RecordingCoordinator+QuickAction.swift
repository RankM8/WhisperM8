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
            hasAccessibilityPermission: { PermissionService.hasAccessibilityPermission },
            requestAccessibilityPermission: { PermissionService.requestAccessibilityPermission() },
            captureSelection: { app in await selectedContextService.captureForQuickAction(from: app) },
            // Leere Sprache = „auto“: Die Markierung behält ihre Sprache,
            // unabhängig von der Diktatsprache. Kein Kontext: die Markierung
            // ist hier der Text selbst, nicht Hintergrund.
            rework: { text, mode in
                try await postProcessingService.processRun(rawText: text, mode: mode, language: "", contextBundle: .empty)
            },
            isTargetUnchanged: { original, app in
                await Self.isQuickActionTargetUnchanged(original: original, app: app)
            },
            replaceSelection: { text, app, rule in
                // Wurde das Zwischenablage-Fenster während der Nacharbeit
                // wieder geöffnet, hält es die Tastatur: Cmd+V landete sonst
                // in seinem Suchfeld statt in der Ziel-App.
                if ClipboardHistoryController.shared.isPanelVisible {
                    ClipboardHistoryController.shared.hidePanel()
                    try? await Task.sleep(for: .milliseconds(150))
                }
                return await replacer.replaceSelection(with: text, in: app, restore: rule)
            },
            copyToClipboard: { pasteService.copyToClipboard($0) },
            recordHistory: { result, original, mode, app in
                historyRecorder(DictationHistoryRecord(
                    text: result, original: original, mode: mode, targetApp: app, isQuickAction: true
                ))
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

    /// Vor dem Einfügen: Ist die App von damals noch vorn, und ist (bei einem
    /// Feld mit Accessibility) noch derselbe Text markiert? Bei Text aus dem
    /// Cmd+C-Rückfall lässt sich die Markierung nicht ohne neues Cmd+C lesen,
    /// dort zählt nur die App.
    /// Regel in `QuickActionTargetCheck`; eine App, die nicht rechtzeitig
    /// antwortet, gilt nicht als „geändert“.
    static func isQuickActionTargetUnchanged(original: CapturedSelection?, app: NSRunningApplication?) async -> Bool {
        guard let app else { return true }
        return await QuickActionTargetCheck.isUnchanged(
            original: original,
            frontmostMatches: NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
            read: { timeout in await SelectedContextService.selectionReadout(of: app, timeout: timeout) }
        )
    }

    /// Aufnahme, Verbindungsaufbau, Transkription oder Nacharbeit laufen.
    var isDictationBusy: Bool {
        guard let appState else { return false }
        return appState.isRecording || appState.isTranscribing || appState.isPostProcessing
            || isProcessing || isStartingRecording
    }
}
