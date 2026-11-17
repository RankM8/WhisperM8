import Foundation

// MARK: - tickets.open (`whisperm8 tickets open <Ticket>`, WM8-131)

/// Öffnet ein Ticket im Ticket-Board der App: Fenster nach vorn, Board des
/// Projekts, zu dessen Team das Ticket gehört, Ticket groß in der Triage.
/// Liest Linear nur, schickt nichts in einen Chat. Prüfen und Zeigen stehen in
/// `TicketOpenService`; hier nur Protokoll und Audit.
extension AgentControlRequestHandler {
    static let ticketsOpenMethod = "tickets.open"

    func ticketsOpen(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        let input = request.params["key"]?.stringValue ?? ""
        let service = await MainActor.run { TicketOpenService.live }
        switch await service.open(input: input) {
        case .opened(let board, let ticket, let shown):
            await audit(request.actor, method: "tickets-open", target: ticket.key, outcome: "ok", prompt: nil)
            return .success(requestID: request.requestID, result: .object([
                "ok": true,
                "key": ticket.key,
                "title": ticket.title,
                "status": ticket.status.name,
                "team": board.team,
                "project": board.projectName,
                "pending": shown == .pending,
            ]))
        case .failed(let code, let message):
            await audit(request.actor, method: "tickets-open", target: TicketOpenTarget.key(fromInput: input),
                        outcome: code.rawValue, prompt: nil)
            return .failure(requestID: request.requestID, code: code, message: message)
        }
    }
}
