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
// L1 + R1. R2 diktiert an den sichtbaren Board-Chat, nie mit Senden; ohne ihn
// tut es nichts, mit Rückmeldung (E4: kein Diktat ohne sichtbares Ziel).
// Dreieck legt das gewählte Ticket ins Feld des Board-Chats („→ Jarvis“,
// Paket 3b). Mit der Liste links im Fokus gelten deren Tasten.

extension ControllerBindingResolver {
    static func tickets(_ gesture: ControllerGesture, state: ControllerTicketState) -> ControllerAction? {
        switch gesture {
        case .tap(.l2): return .lastChat
        case .press(.options): return .menuToggle
        case .press(.create): return .newChat
        case .press(.touchpad): return .clipboardToggle
        // Paket 3b: R2 diktiert an den Board-Chat, den die Spalte zeigt (nie
        // mit Senden). Ohne sichtbaren Board-Chat E4: „geht nicht“ mit Grund.
        case .press(.r2): return state.place.boardChatID == nil ? .ticket(.dictationUnavailable) : .dictationToggle
        default: break
        }
        guard state.area == .content else { return ticketsListFallback(gesture) }
        if let chat = state.boardChat { return ticketsBoardChat(gesture, chat: chat) }
        switch state.place.view {
        case .empty:
            // Kein Stand zum Bedienen: ◀ führt in die Seitenleiste, ▲ in den
            // Kopf (Filter zurücksetzen, Aktualisieren, Paket 3d), der Rest ruht.
            if case .move(.left, _, false) = gesture { return .enterList(step: 0) }
            if case .move(.up, _, false) = gesture { return .ticket(.move(.up)) }
            return nil
        case .board, .list:
            return ticketsBoard(gesture, state: state)
        case .triage, .chatLine:
            return ticketsTriage(gesture, state: state)
        case .header:
            return ticketsHeader(gesture, state: state)
        case .headerPicker:
            return ticketsHeaderPicker(gesture)
        }
    }

    /// Nr. 8 bis 17: Board und Liste.
    private static func ticketsBoard(_ gesture: ControllerGesture, state: ControllerTicketState) -> ControllerAction? {
        if let shared = ticketsShared(gesture, state: state) { return shared }
        switch gesture {
        // Gehalten nach rechts oder oben: bewegt, rutscht am Rand aber nie in
        // den Board-Chat (Paket 3a) oder den Kopf (Paket 3d). Hinein nur mit
        // einem einzelnen Druck.
        case let .move(direction, _, true) where direction == .right || direction == .up:
            return .ticket(.repeatMove(direction))
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
            // Gehalten nach oben: durch die Liste, aber nie in den Kopf (Paket 3d).
            if isRepeat, direction == .up { return .ticket(.repeatMove(.up)) }
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

    /// Paket 3a: Der Controller hat die Tasten im Board-Chat. Es gelten die
    /// Tasten eines Chats mit all seinen Schutzregeln (Ankunftssperre,
    /// Sperre nach einer Frage, Freigabe-Regeln) — aber nur, was in diesen
    /// sichtbaren Chat schreibt oder in ihm blättert. Alles, was einen
    /// anderen Chat wählt, startet oder die Ansicht wechselt, ruht hier.
    ///
    /// - L1/R1: voriges/nächstes Ticket (E2), nicht Chatwechsel.
    /// - Stick ◀: zurück aufs Ticket (Entscheidung 16.11.2026). Steuerkreuz
    ///   bleibt Pfeiltasten ins Terminal; nur wo ← dort nichts tun darf (leeres
    ///   Claude-Feld, kein lebendes Terminal), führt auch es zurück.
    private static func ticketsBoardChat(_ gesture: ControllerGesture, chat: ControllerChatState) -> ControllerAction? {
        switch gesture {
        case .tap(.l1): return .ticket(.adjacent(-1))
        case .tap(.r1): return .ticket(.adjacent(1))
        case .move(.left, .leftStick, false): return .ticket(.leaveBoardChat)
        case .move(_, .leftStick, _): return nil
        case let .move(.left, .dpad, isRepeat):
            if arrowsAllowed(chat), leftArrowAllowed(chat) { return .chatKey(.left) }
            return isRepeat ? nil : .ticket(.leaveBoardChat)
        default:
            break
        }
        guard let action = Self.chat(gesture, state: chat) else { return nil }
        switch action {
        case .chatKey, .chatInterrupt, .chatClearInput, .scroll, .scrollToBottom,
             .holdProgress, .holdProgressCancelled, .rejected:
            return action
        default:
            // Chat starten (über den Kopf der Spalte), Chatwechsel, Liste,
            // Raster, Kachel groß: nicht aus dem Board-Chat heraus.
            return nil
        }
    }

    /// Paket 3d: Auswahl im Kopf. Stick und Steuerkreuz wählen nur (auch
    /// gehalten), Kreuz schaltet, Kreis zurück auf die Karte. L1/R1, Link,
    /// Linear, Aktualisieren und → Jarvis wie auf dem Board.
    private static func ticketsHeader(_ gesture: ControllerGesture, state: ControllerTicketState) -> ControllerAction? {
        if let shared = ticketsShared(gesture, state: state) { return shared }
        switch gesture {
        case let .move(direction, _, _): return .ticket(.move(direction))
        case .press(.cross): return .ticket(.open)
        case .tap(.circle): return .ticket(.back)
        case .holdBegan(.circle): return .rejected
        default: return nil
        }
    }

    /// Paket 3d, Liste der Bereiche (Entscheidung 16.11.2026): ▲ ▼ wählen,
    /// Kreuz übernimmt, Kreis schließt ohne Änderung. Sonst nichts.
    private static func ticketsHeaderPicker(_ gesture: ControllerGesture) -> ControllerAction? {
        switch gesture {
        case let .move(direction, _, _) where direction == .up || direction == .down: return .ticket(.move(direction))
        case .press(.cross): return .ticket(.open)
        case .tap(.circle): return .ticket(.back)
        case .holdBegan(.circle): return .rejected
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
        // Paket 3b: → Jarvis legt das gewählte Ticket ins Feld des sichtbaren
        // Board-Chats. Ohne Board-Chat oder ohne Ticket „geht nicht“.
        case .press(.triangle):
            return state.place.boardChatID != nil && state.place.hasTicket ? .ticket(.handOff) : .rejected
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
