import Foundation

// Belegung im Ticket-Modus (WM8-91, Plan docs/plans/ticket-board-controller.md,
// Nr. 1 bis 29).
//
// Grundsatz: Hinter den Tickets kommt in keinem Chat etwas an — kein Enter,
// kein Escape, keine Taste, kein Diktat. Der Zusammenhang kennt keinen Chat;
// keine Aktion hier schreibt in ein Terminal. „Zum Chat“ geht nur von der
// Chat-Zeile am Ticket aus (▶, dann Kreuz, E3): Dreimal schnell Kreuz führt
// so nie vom Board in einen Chat. Das prüft `ControllerTicketsSafetyTests`
// für jede Geste.
//
// Überall im Ticket-Modus: L2 getippt und gehalten wie im Chat (Rückweg und
// „Wohin“), Options, R1 gehalten (nur die App-Raute), Create, Touchpad,
// L1 + R1. R2 tut nichts, mit Rückmeldung (E4: kein Diktat ohne sichtbares
// Ziel). Dreieck ist für „→ Jarvis“ reserviert (WM8-113) und tut bis dahin
// nichts, mit Rückmeldung. Mit der Liste links im Fokus gelten deren Tasten.

extension ControllerBindingResolver {
    static func tickets(_ gesture: ControllerGesture, state: ControllerTicketState) -> ControllerAction? {
        switch gesture {
        case .tap(.l2): return .lastChat
        case .press(.options): return .menuToggle
        case .press(.create): return .newChat
        case .press(.touchpad): return .clipboardToggle
        // E4: Diktat erst mit dem Board-Chat (WM8-113); „geht nicht“ mit Grund.
        case .press(.r2): return .ticket(.dictationUnavailable)
        default: break
        }
        guard state.area == .content else { return ticketsListFallback(gesture) }
        switch state.place.view {
        case .empty:
            // Kein Stand zum Bedienen: ◀ führt in die Seitenleiste, der Rest ruht.
            if case .move(.left, _, false) = gesture { return .enterList(step: 0) }
            return nil
        case .board, .list:
            return ticketsBoard(gesture, state: state)
        case .triage, .chatLine:
            return ticketsTriage(gesture, state: state)
        }
    }

    /// Nr. 8 bis 17: Board und Liste.
    private static func ticketsBoard(_ gesture: ControllerGesture, state: ControllerTicketState) -> ControllerAction? {
        if let shared = ticketsShared(gesture, state: state) { return shared }
        switch gesture {
        case let .move(direction, _, _): return .ticket(.move(direction))
        case .press(.cross): return state.place.hasTicket ? .ticket(.open) : .ticket(.move(.down))
        // Kreis tut auf dem Board nichts (zweimal Kreis aus der Triage wirft
        // nicht aus dem Board); „L2 Zurück“ steht in der Leiste.
        case .tap(.circle), .holdBegan(.circle): return .rejected
        default: return nil
        }
    }

    /// Nr. 23 bis 29: Ticket groß. Kreuz in der Liste tut nichts; nur auf der
    /// Chat-Zeile führt es zum Chat.
    private static func ticketsTriage(_ gesture: ControllerGesture, state: ControllerTicketState) -> ControllerAction? {
        if let shared = ticketsShared(gesture, state: state) { return shared }
        let onChatLine = state.place.view == .chatLine
        switch gesture {
        case let .move(direction, _, isRepeat):
            // Seitwärts ein Druck, ein Schritt: Halten springt nicht durch Liste und Chats.
            if isRepeat, direction == .left || direction == .right { return nil }
            return .ticket(.move(direction))
        case .press(.cross):
            guard onChatLine else { return .rejected }
            return state.place.chatLineTitle == nil ? .rejected : .ticket(.open)
        case .tap(.circle): return .ticket(.back)
        case .holdBegan(.circle): return .rejected
        case let .scroll(lines): return .ticket(.scroll(lines: lines))
        default: return nil
        }
    }

    /// Was in Board und Triage gleich ist (Nr. 11, 13, 15, 16, 28).
    private static func ticketsShared(_ gesture: ControllerGesture, state: ControllerTicketState) -> ControllerAction? {
        switch gesture {
        case .tap(.l1): return .ticket(.adjacent(-1))
        case .tap(.r1): return .ticket(.adjacent(1))
        case .tap(.square): return state.place.hasTicket ? .ticket(.copyLink) : .rejected
        case .press(.l3): return state.place.hasTicket ? .ticket(.openInLinear) : .rejected
        case .tap(.r3): return .ticket(.refresh)
        // → Jarvis kommt mit dem Board-Chat (WM8-113).
        case .press(.triangle): return .rejected
        default: return nil
        }
    }

    /// Mit der Liste links im Fokus: deren Tasten. Nichts davon erreicht einen
    /// Chat ungesehen; Kreuz öffnet den markierten Chat sichtbar (und verlässt
    /// die Tickets), ▶ und Kreis gehen zurück ins Board.
    private static func ticketsListFallback(_ gesture: ControllerGesture) -> ControllerAction? {
        guard let action = list(gesture) else { return nil }
        switch action {
        case .listMove, .leaveList, .listActivate, .listFilter, .listCloseRow, .holdProgress,
             .holdProgressCancelled, .listStartRow:
            return action
        default:
            return nil
        }
    }

    /// Ebenen im Ticket-Modus: L2 „Wohin“ wie im Chat, R1 nur die App-Raute
    /// (die Chat-Raute bleibt aus, bis es den Board-Chat gibt), L1 „Schreiben“
    /// gibt es nicht. Unter L1 wirken die Tasten wie ohne Ebene.
    static func ticketsLayer(_ gesture: ControllerGesture, state: ControllerTicketState) -> ControllerAction? {
        switch gesture {
        case let .layerBegan(layer): return layer == .writing ? nil : .islandShow(layer)
        case let .inLayer(layer, inner):
            switch layer {
            case .whereTo: return whereToLayer(inner)
            case .writing: return tickets(inner, state: state)
            case .quickDraw:
                if inner == .press(.r2) { return .rejected }
                if case .press(let button) = inner, ControllerQuickDrawSlots.item(for: button) != nil || button == .l3 {
                    return .rejected
                }
                return appDiamond(inner)
            }
        default:
            return nil
        }
    }
}
