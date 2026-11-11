import Foundation

// Belegung im Zusammenhang `chat` (Plan, „Im Inhalt“ und „Kreuz, Kreis und
// Viereck im Chat“).

extension ControllerBindingResolver {
    /// Kreuz ist nach einer neuen Rückfrage so lange ohne Wirkung, damit ein
    /// Reflex-Druck keine Freigabe erteilt.
    static let confirmLockAfterQuestion: TimeInterval = 0.5

    static func chat(_ gesture: ControllerGesture, state: ControllerChatState) -> ControllerAction? {
        switch gesture {
        // Navigation: wirkt auch bei beendetem Chat oder reinem Verlauf.
        case let .move(direction, .leftStick, isRepeat):
            return leftStick(direction, isRepeat: isRepeat, gridActive: state.gridActive)
        // L1/R1 folgen der Liste links, nicht den Tabs (die Tastatur bleibt bei den Tabs).
        case .press(.l1): return .adjacentChat(step: -1)
        case .press(.r1): return .adjacentChat(step: 1)
        case .press(.triangle): return .nextWaitingChat
        // Der Ausführer entscheidet: Kachel groß oder zurück zum Raster.
        case .press(.l3): return .toggleMaximize
        case .press(.create): return .newChat
        case .press(.options): return .menuToggle
        // R3 startet einen gestoppten Chat. Auf einem lebenden nichts, auch
        // keine Vibration: beim Scrollen drückt man ihn leicht aus Versehen.
        case .press(.r3): return state.acceptsKeys ? nil : .chatResume
        case .press(.touchpad): return .clipboardToggle
        case .press(.r2): return .dictationToggle
        case .tap(.l2): return .lastChat
        // Im Raster öffnet L2 halten die Workspace-Auswahl (Runde 3), in der
        // Einzelansicht die Chat-Auswahl. Die Tastatur (Ctrl+Tab) bleibt bei den Chats.
        case .holdBegan(.l2): return state.gridActive ? .workspacePickerBegin : .pickerBegin
        case let .holdPending(.l2, duration): return .holdProgress(.l2, duration: duration)
        case .holdCancelled(.l2): return .holdProgressCancelled(.l2)
        case let .scroll(lines): return .scroll(lines: lines)

        // Tasten ins Terminal: nur bei lebendem Chat.
        case let .move(direction, .dpad, _):
            return state.acceptsKeys ? .chatKey(ControllerChatKey(direction)) : nil
        case .press(.cross):
            // Gestoppter Chat: Kreuz startet ihn wieder (wie „Starten“ im Kopf).
            guard state.acceptsKeys else { return .chatResume }
            return confirmAllowed(state) ? .chatKey(.enter) : nil
        case .tap(.circle):
            return escapeAllowed(state) ? .chatKey(.escape) : nil
        case .holdBegan(.circle):
            return interruptAllowed(state) ? .chatInterrupt : nil
        case let .holdPending(.circle, duration):
            return interruptAllowed(state) ? .holdProgress(.circle, duration: duration) : nil
        case .holdCancelled(.circle):
            return interruptAllowed(state) ? .holdProgressCancelled(.circle) : nil
        // Rücktaste: tippen löscht ein Zeichen, halten löscht weiter wie eine
        // gehaltene Taste. Harmlos in jedem lebenden Zustand.
        case .tap(.square), .holdBegan(.square), .holdRepeat(.square):
            return state.acceptsKeys ? .chatKey(.backspace) : nil

        default:
            return nil
        }
    }

    /// Enter in jedem lebenden Zustand, außer in den ersten 0,5 s einer
    /// Rückfrage. Ist der Beginn der Rückfrage unbekannt, gilt sie als alt.
    static func confirmAllowed(_ state: ControllerChatState) -> Bool {
        guard state.acceptsKeys else { return false }
        if state.status == .awaitingInput,
           let seconds = state.secondsSinceAwaitingBegan,
           seconds < confirmLockAfterQuestion {
            return false
        }
        return true
    }

    /// Escape (tippen) nur, wenn der Chat ruht oder fragt und nicht gerade
    /// etwas gesendet wurde. Ein zweites Escape innerhalb 1 s wird
    /// verschluckt, sonst öffnet Claude das Zurückspulen.
    static func escapeAllowed(_ state: ControllerChatState) -> Bool {
        guard state.acceptsKeys, !state.recentlySubmitted, !state.escapeSentRecently else { return false }
        return state.status == .idle || state.status == .awaitingInput
    }

    /// Unterbrechen (Kreis halten) nur, wenn der Chat arbeitet, sein Zustand
    /// unklar ist oder gerade gesendet wurde. Auch hier kein zweites Escape
    /// innerhalb 1 s.
    static func interruptAllowed(_ state: ControllerChatState) -> Bool {
        guard state.acceptsKeys, !state.escapeSentRecently else { return false }
        return state.status == .working || state.status == .unknown || state.recentlySubmitted
    }

    /// Linker Stick im Inhalt. Im Raster bewegt er den Kachel-Fokus (ein
    /// Druck, ein Schritt). In der Einzelansicht springen hoch und runter mit
    /// der Markierung in die Liste links — Start beim aktuellen Chat, sofort
    /// ein Schritt in die gedrückte Richtung; der offene Chat bleibt
    /// (Runde 3). Hält man weiter, kommen die Wiederholungen schon im
    /// Zusammenhang `list` an und bewegen dort die Markierung. Links führt in
    /// die Liste.
    static func leftStick(_ direction: ControllerDirection, isRepeat: Bool, gridActive: Bool) -> ControllerAction? {
        guard !isRepeat else { return nil }
        if !gridActive {
            switch direction {
            case .up: return .enterList(step: -1)
            case .down: return .enterList(step: 1)
            case .left, .right: break
            }
        }
        return .moveInContent(direction)
    }
}
