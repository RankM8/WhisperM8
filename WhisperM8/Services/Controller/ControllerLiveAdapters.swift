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
            lastEnterAt: controller.lastSubmitAt,
            lastEscapeAt: controller.lastControlEscapeAt
        )
    }

    func sendKey(_ key: TerminalControlKey, to sessionID: UUID) -> Bool {
        controller(for: sessionID)?.sendKey(key) ?? false
    }

    func clearComposer(of sessionID: UUID) {
        controller(for: sessionID)?.sendComposerClear()
    }

    func scroll(lines: Int, in sessionID: UUID) {
        controller(for: sessionID)?.scrollHistory(lines: lines)
    }

    func sendText(_ text: String, submit: Bool, to sessionID: UUID) -> Bool {
        guard let controller = controller(for: sessionID), controller.isRunning else { return false }
        controller.sendPrompt(text, submit: submit)
        return true
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
            for _ in 0..<100 where appState.isStartingRecording {
                try? await Task.sleep(for: .milliseconds(50))
            }
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

    func toggleClipboardPanel() {
        ClipboardHistoryController.shared.togglePanel()
    }

    func clipboard(_ command: ControllerClipboardCommand) {
        let keyCommand: ClipboardKeyCommand
        switch command {
        case .up: keyCommand = .moveUp
        case .down: keyCommand = .moveDown
        case .paste: keyCommand = .paste
        case .pin: keyCommand = .togglePin
        case .delete: keyCommand = .delete
        case .close: keyCommand = .close
        }
        ClipboardHistoryController.shared.perform(keyCommand)
    }

    func bringAgentChatsToFront() {
        WindowRequestCenter.shared.request(.agentChats)
    }

    func postBridgeKey(_ key: ControllerBridgeKey) {
        ControllerKeyboardBridge.post(key)
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
                ui: .shared
            )
            dispatcher.playHaptic = { [weak manager] in manager?.play($0) }
            dispatcher.togglePause = { [weak manager] in manager?.togglePause() }
            dispatcher.debugOverride = { [weak manager] in manager?.debugOverride }
            dispatcher.titleForSession = { id in
                AgentWorkspaceUIModel.shared.workspace.sessions.first { $0.id == id }?.title
            }
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
