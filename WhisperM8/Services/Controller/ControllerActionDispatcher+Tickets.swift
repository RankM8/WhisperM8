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
        let outcome = chats.ticketCommand(command, in: targetWindowID)
        switch outcome {
        case .done:
            switch command {
            case .copyLink: noteTicket(.linkCopied)
            case .copyList: noteTicket(.listCopied)
            case .refresh: noteTicket(.refreshing)
            default: break
            }
            // Board ↔ Triage ↔ Chat-Zeile: Die Leiste zeigt gleich die neuen Tasten.
            switch command {
            case .open, .back, .move, .goToChat: refreshContext()
            default: break
            }
        case .nothing:
            break
        case .rejected:
            playHaptic(.rejected)
        case .leftEdge:
            // Wie aus dem Inhalt eines Chats: in die Seitenleiste.
            perform(.enterList(step: 0), in: ui.context)
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
