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
        case let .move(direction, .leftStick, false): return .moveInContent(direction)
        case .press(.l1): return .tab(step: -1)
        case .press(.r1): return .tab(step: 1)
        case .press(.triangle): return .nextWaitingChat
        // Der Ausführer entscheidet: Kachel groß oder zurück zum Raster.
        case .press(.l3): return .toggleMaximize
        case .press(.create): return .newChat
        case .press(.options): return .menuToggle
        case .press(.touchpad): return .clipboardToggle
        case .press(.r2): return .dictationToggle
        case .tap(.l2): return .lastChat
        case .holdBegan(.l2): return .pickerBegin
        case let .holdPending(.l2, duration): return .holdProgress(.l2, duration: duration)
        case .holdCancelled(.l2): return .holdProgressCancelled(.l2)
        case let .scroll(lines): return .scroll(lines: lines)

        // Tasten ins Terminal: nur bei lebendem Chat.
        case let .move(direction, .dpad, _):
            return state.acceptsKeys ? .chatKey(ControllerChatKey(direction)) : nil
        case .press(.cross):
            return confirmAllowed(state) ? .chatKey(.enter) : nil
        case .tap(.circle):
            return escapeAllowed(state) ? .chatKey(.escape) : nil
        case .holdBegan(.circle):
            return interruptAllowed(state) ? .chatInterrupt : nil
        case let .holdPending(.circle, duration):
            return interruptAllowed(state) ? .holdProgress(.circle, duration: duration) : nil
        case .holdCancelled(.circle):
            return interruptAllowed(state) ? .holdProgressCancelled(.circle) : nil
        case .tap(.square):
            return clearComposerAllowed(state) ? .chatClearComposer : nil

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

    /// Viereck sendet Ctrl+C und ist deshalb nur bei Claude, ruhendem Chat und
    /// erkanntem Entwurf aktiv.
    static func clearComposerAllowed(_ state: ControllerChatState) -> Bool {
        state.acceptsKeys && state.profile == .claude && state.status == .idle
            && state.draftSuspected && !state.recentlySubmitted
    }
}
