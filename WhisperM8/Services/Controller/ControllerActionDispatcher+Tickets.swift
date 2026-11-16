import Foundation

/// Ticket-Board am Controller (WM8-91, Paket 2): Befehle an das Board des
/// Fensters und die kurze Bestätigung in der Leiste. Die Regeln stehen pur in
/// `TicketBoardSelection`; das Fenster wendet sie an.
extension ControllerActionDispatcher {
    func performTicket(_ command: ControllerTicketCommand) {
        if command == .dictationUnavailable {
            playHaptic(.rejected)
            return noteTicket(.dictationNeedsBoardChat)
        }
        if command == .leaveBoardChat { return leaveBoardChat() }
        // „Zum Chat“: Kreuz und Kreis warten im Ziel-Chat (WM8-91), fest an
        // seiner ID, auch wenn das Fenster die Auswahl erst später meldet.
        var target: UUID?
        switch command {
        case let .goToChat(chatID): target = chatID
        case .open: target = targetWindowID.flatMap { chats.snapshot(of: $0) }?.tickets?.chatLineChatID
        default: target = nil
        }
        let outcome = chats.ticketCommand(command, in: targetWindowID)
        if outcome == .done, let target { noteArrival(at: target, before: nil) }
        switch outcome {
        case .done:
            switch command {
            case .copyLink: noteTicket(.linkCopied)
            case .copyList: noteTicket(.listCopied)
            case .refresh: noteTicket(.refreshing)
            case .handOff: noteTicket(.handedOff)
            default: break
            }
            // Board ↔ Triage ↔ Chat-Zeile: Die Leiste zeigt gleich die neuen Tasten.
            switch command {
            case .open, .back, .move, .repeatMove, .goToChat: refreshContext()
            default: break
            }
        case .nothing:
            break
        case .rejected:
            playHaptic(.rejected)
        case .leftEdge:
            // Wie aus dem Inhalt eines Chats: in die Seitenleiste.
            perform(.enterList(step: 0), in: ui.context)
        case .rightEdge:
            enterBoardChat()
        case .topEdge:
            // Wandelt das Fenster selbst in den Einstieg in den Kopf um.
            break
        case .goBack:
            // „← Chats“ im Kopf (Paket 3d): derselbe Weg wie L2 getippt, mit
            // Ankunftssperre im Ziel-Chat.
            perform(.lastChat, in: ui.context)
        }
    }

    // MARK: - Board-Chat (Paket 3a)

    /// Rechts über den Rand: Der Controller hat jetzt die Tasten im
    /// Board-Chat, den die Spalte zeigt. Kreuz und Kreis warten dort die
    /// Ankunftssperre ab (1 s, fest an seiner ID), wie nach „Zum Chat“. Ohne
    /// sichtbaren Board-Chat (keiner, zugeklappt, anderes Fenster) „geht nicht“.
    func enterBoardChat() {
        guard let windowID = targetWindowID, let place = chats.snapshot(of: windowID)?.tickets,
              let sessionID = place.boardChatID else {
            return playHaptic(.rejected)
        }
        ui.leaveList()
        ui.boardChatFocus = ControllerBoardChatFocus(windowID: windowID, sessionID: sessionID)
        noteArrival(at: sessionID, before: nil)
        refreshContext()
    }

    /// Stick ◀ im Board-Chat: zurück aufs Ticket, auf dem man war. Board und
    /// Triage haben ihre Auswahl behalten; nichts geht an den Chat.
    func leaveBoardChat() {
        guard ui.boardChatFocus != nil else { return }
        ui.boardChatFocus = nil
        refreshContext()
    }

    /// Fokus im Board-Chat nur, solange genau dieser Chat in der Spalte des
    /// Fensters steht, das der Controller bedient.
    func dropStaleBoardChatFocus() {
        guard let focus = ui.boardChatFocus else { return }
        if let windowID = targetWindowID,
           focus.isValid(windowID: windowID, place: chats.snapshot(of: windowID)?.tickets) { return }
        ui.boardChatFocus = nil
    }

    /// Der Chat, in den Tasten, Scrollen und Leeren des Controllers gehen.
    /// Ohne Tickets der ausgewählte Chat. Hinter den Tickets nur der
    /// Board-Chat mit dem Fokus des Controllers, sonst keiner: So erreicht
    /// keine Taste den verdeckten Chat, auch wenn eine Belegung es einmal
    /// zuließe (zweite Sicherung neben `ControllerTicketsSafetyTests`).
    var chatInputSessionID: UUID? {
        guard let windowID = targetWindowID, let window = chats.snapshot(of: windowID) else { return nil }
        guard let place = window.tickets else { return window.selectedSessionID }
        guard let focus = ui.boardChatFocus, focus.isValid(windowID: windowID, place: place) else { return nil }
        return focus.sessionID
    }

    /// Zustand des Chats, in den Tasten gehen: im Chat dessen, im Board-Chat
    /// der des Board-Chats, sonst keiner.
    static func inputChatState(_ context: ControllerContext) -> ControllerChatState? {
        switch context {
        case let .chat(state): return state
        case let .tickets(state): return state.area == .content ? state.boardChat : nil
        default: return nil
        }
    }

    /// Bestätigung für 2 s; eine neuere ersetzt sie.
    func noteTicket(_ notice: ControllerTicketNotice) {
        ui.ticketNotice = notice
        ticketNoticeGeneration += 1
        let generation = ticketNoticeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.ticketNoticeGeneration == generation else { return }
            self.ui.ticketNotice = nil
        }
    }
}
