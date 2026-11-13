import AppKit
import Foundation

// Live-Anbindungen des `ControllerActionDispatcher` an die App.

/// Terminals der Chats: Zustand lesen, Tasten und Text schicken, scrollen.
@MainActor
final class LiveControllerTerminals: ControllerTerminalControlling {
    private func controller(for sessionID: UUID) -> AgentTerminalController? {
        AgentTerminalRegistry.shared.controller(for: sessionID)
    }

    func state(of sessionID: UUID) -> ControllerTerminalState? {
        guard let controller = controller(for: sessionID) else { return nil }
        let coordinator = AgentSessionStatusCoordinator.shared
        let profile: ControllerChatState.Profile
        switch controller.command.keyboardProfile {
        case .claudeCodeChat: profile = .claude
        case .codexChat: profile = .codex
        case .plainShell: profile = .shell
        case .claudeAgentsView: profile = .other
        }
        return ControllerTerminalState(
            isRunning: controller.isRunning,
            profile: profile,
            status: coordinator.statusStore.status(for: sessionID),
            statusSince: coordinator.activityStore.statusSince(for: sessionID),
            draftSuspected: controller.composerDraft.mayHaveUnsentInput,
            fieldMayHaveText: controller.composerDraft.fieldMayHaveText,
            lastEnterAt: controller.lastSubmitAt,
            lastEscapeAt: controller.controllerMarks.lastEscapeAt,
            lastDraftInputAt: controller.controllerMarks.lastDraftInputAt,
            lastArmingArrowAt: controller.controllerMarks.lastArmingArrowAt,
            choiceListOpen: controller.controllerChoiceListOpen(status: coordinator.statusStore.status(for: sessionID)),
            shellAtPrompt: profile == .shell && !controller.terminal.getTerminal().isCurrentBufferAlternate,
            screen: controller.controllerScreenSnapshot(),
            queuedOwnPrompts: profile == .claude ? coordinator.queuedOwnPrompts(sessionID: sessionID) : 0,
            onlyRecalledPrompt: controller.composerDraft.holdsOnlyRecalledPrompt,
            bracketedPaste: controller.terminal.getTerminal().bracketedPasteMode
        )
    }

    func sendKey(_ key: TerminalControlKey, to sessionID: UUID) -> Bool {
        controller(for: sessionID)?.sendKey(key) ?? false
    }

    func clearInput(in sessionID: UUID) -> Bool {
        controller(for: sessionID)?.clearInputFromController() ?? false
    }

    func scroll(lines: Int, in sessionID: UUID) {
        controller(for: sessionID)?.scrollHistory(lines: lines)
    }

    func sendText(_ text: String, submit: Bool, to sessionID: UUID) -> Bool {
        guard let controller = controller(for: sessionID), controller.isRunning else { return false }
        controller.sendPrompt(text, submit: submit)
        controller.noteControllerDraftInput(submitted: submit)
        return true
    }

    func noteChoiceListOpened(in sessionID: UUID) {
        controller(for: sessionID)?.noteControllerChoiceListOpened(
            status: AgentSessionStatusCoordinator.shared.statusStore.status(for: sessionID))
    }
}

/// Diktat: derselbe Weg wie der Hotkey, über `AppState`.
@MainActor
final class LiveControllerDictation: ControllerDictationControlling {
    var phase: ControllerRecordingPhase? {
        // Während das Mikrofon verbindet, zählt das schon als Aufnahme: R2
        // beendet, Kreis verwirft — nichts davon darf in den Chat gehen.
        if AppState.shared.isStartingRecording { return .recording }
        switch AppState.shared.recordingPhase {
        case .idle: return nil
        case .recording: return .recording
        case .transcribing: return .transcribing
        case .postProcessing: return .postProcessing
        }
    }

    var isQuickActionRunning: Bool { AppState.shared.isQuickActionRunning }

    var targetSessionID: UUID? { AppState.shared.dictationTargetSessionID }

    func start(target: DictationDeliveryTarget, label: String?) {
        Task { @MainActor in
            let appState = AppState.shared
            await appState.startRecording(target: target)
            // Erst nach dem Start: Der Start blendet die Pill zuvor einmal aus.
            if appState.isRecording { appState.showControllerDictationTarget(label) }
        }
    }

    func stop(submit: Bool) {
        Task { @MainActor in
            let appState = AppState.shared
            // Kommt das Stoppen, während das Mikrofon noch verbindet, gilt es,
            // sobald die Aufnahme läuft (höchstens 5 s warten).
            var waited = false
            for _ in 0..<100 where appState.isStartingRecording {
                waited = true
                try? await Task.sleep(for: .milliseconds(50))
            }
            // Ein Stoppen in den ersten 0,3 s einer Aufnahme verwirft der
            // Coordinator (Tipp-Regel des Hotkeys) — dann kurz abwarten.
            if waited { try? await Task.sleep(for: .milliseconds(350)) }
            await appState.stopRecording(submit: submit)
        }
    }

    func cancel() {
        let appState = AppState.shared
        if appState.isQuickActionRunning {
            appState.cancelQuickAction()
            return
        }
        if appState.isStartingRecording {
            appState.cancelRecording()
            return
        }
        switch appState.recordingPhase {
        case .idle: break
        case .recording: appState.cancelRecording()
        case .transcribing: appState.cancelTranscription()
        case .postProcessing: appState.cancelPostProcessing()
        }
    }

    func stepOutputMode(_ step: Int) {
        AppState.shared.stepOutputMode(step)
    }
}

/// Fenster, Zwischenablage-Verlauf und die Tastatur-Brücke.
@MainActor
final class LiveControllerEnvironment: ControllerAppEnvironment {
    private var isMenuTracking = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isMenuTracking = true }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isMenuTracking = false }
            },
        ]
    }

    var isAppActive: Bool { NSApp.isActive }

    var hasOtherKeyWindow: Bool { NSApp.keyWindow != nil }

    var isModalOpen: Bool {
        if isMenuTracking { return true }
        guard let keyWindow = NSApp.keyWindow else { return false }
        // Popover hängen als eigenes kleines Fenster am Hauptfenster.
        if keyWindow.parent != nil, keyWindow is NSPanel { return true }
        // Ein Textfeld mit Fokus (Filter, Suche): Dessen Feld-Editor ist ein
        // editierbarer NSTextView. Das Terminal ist keiner, der Verlauf ist
        // nicht editierbar.
        if let text = keyWindow.firstResponder as? NSTextView, text.isEditable { return true }
        return false
    }

    var isClipboardPanelOpen: Bool { ClipboardHistoryController.shared.isPanelVisible }

    var clipboardState: ControllerClipboardState { ClipboardHistoryController.shared.controllerState }

    func toggleClipboardPanel() {
        ClipboardHistoryController.shared.togglePanel()
    }

    func clipboard(_ command: ControllerClipboardCommand) {
        ClipboardHistoryController.shared.perform(controller: command)
    }

    func bringAgentChatsToFront() {
        WindowRequestCenter.shared.request(.agentChats)
    }

    func postBridgeKey(_ key: ControllerBridgeKey) {
        ControllerKeyboardBridge.post(key)
    }

    var appToggles: ControllerAppToggles {
        let stayAwake = StayAwakeController.shared
        return ControllerAppToggles(
            alert: ControllerAlertStage(AppPreferences.shared.agentAlertLevel),
            nextAlert: ControllerAlertStage(AgentAlertLevel.nextLevel()),
            awake: ControllerAwakeStage(stayAwake.mode),
            awakeNeedsPermission: stayAwake.nextStepNeedsPermission)
    }

    func cycleAlertLevel() -> ControllerAlertStage {
        ControllerAlertStage(AgentAlertLevel.advance())
    }

    /// Wie der Wach-Knopf, aber ohne Admin-Dialog: Fehlt die Freigabe, sagt
    /// die Insel, wo sie zu erteilen ist.
    func cycleStayAwake(_ completion: @escaping @MainActor (ControllerStayAwakeResult) -> Void) {
        let stayAwake = StayAwakeController.shared
        // War die Seitenleiste seit dem Start verborgen, ist die Freigabe noch
        // unbekannt: erst still prüfen (`sudo -n`, nie ein Dialog).
        stayAwake.whenPermissionKnown {
            guard !stayAwake.isAwaitingPermission else { return completion(.busy) }
            guard !stayAwake.nextStepNeedsPermission else { return completion(.needsPermission) }
            stayAwake.cycle()
            completion(.changed(ControllerAwakeStage(stayAwake.mode)))
        }
    }

    func openControllerSettings() {
        WindowRequestCenter.shared.requestSettings(routeID: SettingsPage.controller.rawValue)
    }
}

/// Tastatur-Brücke: macht aus Controller-Tasten echte Tastatur-Ereignisse für
/// die eigene App — für Dialoge, Sheets und Fenster ohne eigene
/// Controller-Führung. Die Ereignisse gehen nur in die eigene
/// Ereignisschlange (`NSApp.postEvent`), nie an andere Programme, und
/// brauchen deshalb keine Bedienungshilfen-Berechtigung.
enum ControllerKeyboardBridge {
    /// Markierung in `eventSourceUserData`, an der die App ihre eigenen
    /// Brücken-Ereignisse erkennt („WM8C“).
    static let marker: Int64 = 0x574D_3843

    struct KeyStroke: Equatable {
        var keyCode: CGKeyCode
        var flags: CGEventFlags
    }

    static func keyStroke(for key: ControllerBridgeKey) -> KeyStroke {
        // Pfeiltasten tragen bei echter Tastatur diese beiden Flags.
        let arrow: CGEventFlags = [.maskNumericPad, .maskSecondaryFn]
        switch key {
        case .up: return KeyStroke(keyCode: 126, flags: arrow)
        case .down: return KeyStroke(keyCode: 125, flags: arrow)
        case .left: return KeyStroke(keyCode: 123, flags: arrow)
        case .right: return KeyStroke(keyCode: 124, flags: arrow)
        case .returnKey: return KeyStroke(keyCode: 36, flags: [])
        case .escape: return KeyStroke(keyCode: 53, flags: [])
        case .tab: return KeyStroke(keyCode: 48, flags: [])
        case .backTab: return KeyStroke(keyCode: 48, flags: .maskShift)
        }
    }

    /// Baut Drücken und Loslassen als `NSEvent`. `nil`, wenn das System kein
    /// Ereignis erzeugen kann.
    static func events(for key: ControllerBridgeKey) -> [NSEvent] {
        let stroke = keyStroke(for: key)
        return [true, false].compactMap { isDown in
            guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: stroke.keyCode, keyDown: isDown) else {
                return nil
            }
            cgEvent.flags = stroke.flags
            cgEvent.setIntegerValueField(.eventSourceUserData, value: marker)
            return NSEvent(cgEvent: cgEvent)
        }
    }

    @MainActor
    static func post(_ key: ControllerBridgeKey) {
        guard NSApp.isActive, NSApp.keyWindow != nil else { return }
        for event in events(for: key) {
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// Stammt dieses Tastatur-Ereignis aus der Brücke?
    static func isBridgeEvent(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == marker
    }
}

/// Baut die Live-Kette der Controller-Steuerung zusammen und hält sie.
@MainActor
final class ControllerRuntime {
    static let shared = ControllerRuntime()

    private(set) var dispatcher: ControllerActionDispatcher?
    private(set) var feedback: ControllerFeedback?

    /// Beim App-Start: Ausführer anschließen und den Lauf mit den Schaltern
    /// abgleichen. Idempotent.
    func start(manager: ControllerManager? = nil) {
        let manager = manager ?? .shared
        if dispatcher == nil {
            let dispatcher = ControllerActionDispatcher(
                chats: .shared,
                terminals: LiveControllerTerminals(),
                dictation: LiveControllerDictation(),
                environment: LiveControllerEnvironment(),
                ui: .shared,
                island: ControllerIslandPresenter.shared
            )
            dispatcher.playHaptic = { [weak manager] in manager?.play($0) }
            dispatcher.togglePause = { [weak manager] in manager?.togglePause() }
            dispatcher.debugOverride = { [weak manager] in manager?.debugOverride }
            dispatcher.titleForSession = { id in
                AgentWorkspaceUIModel.shared.workspace.sessions.first { $0.id == id }?.title
            }
            dispatcher.islandChatRows = { order, current in
                ControllerIslandRows.chatRows(order: order, current: current)
            }
            dispatcher.islandStatus = { id in
                ControllerIslandRows.status(AgentSessionStatusCoordinator.shared.statusStore.status(for: id))
            }
            dispatcher.clipboard = ControllerClipboardAccess(
                newest: { LiveControllerClipboard.newest() },
                loadText: { LiveControllerClipboard.loadText(id: $0, completion: $1) },
                copyImage: { LiveControllerClipboard.copyImage(id: $0, completion: $1) })
            dispatcher.closedChats = ControllerClosedChatsAccess(
                nextTitle: { ClosedChatReopener.next()?.title },
                reopen: { ClosedChatReopener.reopen() != nil })
            dispatcher.accountLimit = { kind, name in
                AccountLimitsStore.shared.limit(kind: kind, name: name).map { (fiveHour: $0.fiveHour, week: $0.week) }
            }
            dispatcher.refreshAccountLimits = { AccountLimitsStore.shared.refreshIfStale() }
            dispatcher.limits = ControllerLimitsAccess(
                accounts: { ControllerLimitRows.liveAccounts() },
                rows: { ControllerLimitRows.live($0) },
                updatedAt: { AccountLimitsStore.shared.updatedAt },
                isLoading: { AccountLimitsStore.shared.isLoading },
                refreshIfStale: { AccountLimitsStore.shared.refreshIfStale() },
                refresh: { AccountLimitsStore.shared.refresh() })
            AccountLimitsStore.shared.onChange = { [weak dispatcher] in dispatcher?.accountLimitsChanged() }
            manager.performer = dispatcher
            let feedback = ControllerFeedback(manager: manager, dispatcher: dispatcher)
            manager.onStateChange = { [weak feedback, weak manager, weak dispatcher] in
                // Getrennt, ausgeschaltet oder pausiert: Auswahl, Menü und
                // Liste schließen ohne Wirkung.
                if let manager, manager.status.device == nil || !manager.status.isRunning || manager.isPaused {
                    dispatcher?.closeControllerUI()
                }
                feedback?.sync()
                feedback?.refresh()
            }
            manager.onResolution = { [weak feedback] resolution in
                // Endet ein Halten ohne Aktion, bliebe der Ring sonst stehen.
                if resolution.gesture.endsHold, !resolution.startsHoldProgress {
                    ControllerUIModel.shared.holdProgress = nil
                }
                feedback?.refresh()
            }
            self.dispatcher = dispatcher
            self.feedback = feedback
        }
        manager.applyPreferences()
        ControllerConnectHint.shared.sync()
    }
}

private extension ControllerGesture {
    /// Ein Halten ist zu Ende (ausgelöst, losgelassen, abgebrochen).
    var endsHold: Bool {
        switch self {
        case .holdBegan, .holdEnded, .holdCancelled, .chordCompleted, .chordCancelled: return true
        default: return false
        }
    }
}

private extension ControllerResolution {
    var startsHoldProgress: Bool {
        if case .holdProgress = action { return true }
        return false
    }
}
