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
            return navigate(direction, isRepeat: isRepeat, gridActive: state.gridActive)
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

        // Steuerkreuz: Pfeile ins Terminal nur in einer Rückfrage. Sonst
        // richten sie Schaden an — links im leeren Eingabefeld schickt Claude
        // in den Hintergrund, hoch holt den letzten Prompt zurück (Kreuz
        // schickte ihn erneut), in einer Shell den letzten Befehl. Außerhalb
        // einer Rückfrage wirkt das Steuerkreuz deshalb wie der linke Stick.
        // Bewusst nicht am Entwurfs-Verdacht festgemacht: Die Rücktaste setzt
        // ihn nie zurück.
        case let .move(direction, .dpad, isRepeat):
            if arrowsAllowed(state) { return .chatKey(ControllerChatKey(direction)) }
            return navigate(direction, isRepeat: isRepeat, gridActive: state.gridActive)

        // Tasten ins Terminal: nur bei lebendem Chat.
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

    /// Pfeiltasten ins Terminal nur bei offener Rückfrage eines lebenden Chats.
    static func arrowsAllowed(_ state: ControllerChatState) -> Bool {
        state.acceptsKeys && state.status == .awaitingInput
    }

    /// Enter: im Ruhezustand immer, in einer Rückfrage nach den ersten 0,5 s
    /// (unbekannter Beginn gilt als alt). Arbeitet der Chat oder ist sein
    /// Zustand unklar, nur wenn kurz vorher per Controller getippt, gelöscht
    /// oder diktiert wurde: Zwischen dem Erscheinen eines Freigabe-Dialogs und
    /// dem Status „wartet“ liegt eine Lücke, in der Enter sonst die
    /// Vorauswahl bestätigte.
    static func confirmAllowed(_ state: ControllerChatState) -> Bool {
        guard state.acceptsKeys else { return false }
        switch state.status {
        case .awaitingInput:
            if let seconds = state.secondsSinceAwaitingBegan, seconds < confirmLockAfterQuestion { return false }
            return true
        case .idle:
            return true
        case .working, .unknown:
            return state.recentDraftInput
        case .ended:
            return false
        }
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

    /// Linker Stick (und Steuerkreuz außerhalb von Rückfragen) im Inhalt. Im
    /// Raster bewegt er den Kachel-Fokus (ein Druck, ein Schritt). In der
    /// Einzelansicht springen hoch und runter mit der Markierung in die Liste
    /// links — Start beim aktuellen Chat, sofort ein Schritt in die gedrückte
    /// Richtung; der offene Chat bleibt (Runde 3). Hält man weiter, kommen die
    /// Wiederholungen schon im Zusammenhang `list` an und bewegen dort die
    /// Markierung. Links führt in die Liste, rechts hat dort keine Wirkung.
    static func navigate(_ direction: ControllerDirection, isRepeat: Bool, gridActive: Bool) -> ControllerAction? {
        guard !isRepeat else { return nil }
        if !gridActive {
            switch direction {
            case .up: return .enterList(step: -1)
            case .down: return .enterList(step: 1)
            case .left: break
            case .right: return nil
            }
        }
        return .moveInContent(direction)
    }
}
