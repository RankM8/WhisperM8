import Foundation

// MARK: - `whisperm8 tickets open <Ticket>` (WM8-131)

/// Antwort der App auf `tickets.open`.
enum TicketsOpenReply: Equatable {
    /// `pending`: Das Board lädt noch; das Ticket springt auf, sobald es steht.
    case opened(key: String, title: String, status: String, team: String, project: String, pending: Bool = false)
    case refused(exitCode: Int32, message: String)
}

/// Öffnet ein Ticket im Ticket-Board der laufenden App. Die App prüft und
/// zeigt (sie ist die einzige, die Fenster hat); die Kommandozeile reicht nur
/// die Nummer weiter und gibt die Antwort aus. Liest Linear nicht selbst.
enum TicketsOpenCommand {
    static func execute(key: String, json: Bool, send: (String) -> TicketsOpenReply) -> TicketsCLIRunner.Output {
        switch send(key) {
        case let .opened(key, title, status, team, project, pending):
            if json {
                let object: [String: Any] = ["ok": true, "key": key, "title": title, "status": status, "team": team,
                                             "project": project, "pending": pending]
                return TicketsCLIRunner.Output(exitCode: TicketsCLIExit.ok, stdout: TicketsCLIFormatter.jsonString(object))
            }
            // „Offen“ nur, wenn es wirklich offen ist; lädt das Board noch, ist es erst vorgemerkt.
            let state = pending
                ? "ist im Ticket-Board von \(project) vorgemerkt und öffnet sich, sobald das Board geladen ist."
                : "steht im Ticket-Board von \(project) offen."
            return TicketsCLIRunner.Output(exitCode: TicketsCLIExit.ok, stdout: "✓ \(key) (\(title), \(status)) \(state)")
        case let .refused(exitCode, message):
            return TicketsCLIRunner.Output(exitCode: exitCode, stderr: message)
        }
    }

    /// Exit-Code zu einem Fehler der App. Linear nicht ladbar heißt wie bei
    /// den anderen Befehlen 5; die Ticket-Ansicht aus oder kein Fenster 4.
    static func exitCode(for code: ChatsControlErrorCode) -> Int32 {
        switch code {
        case .invalid: return TicketsCLIExit.usage
        case .notFound: return TicketsCLIExit.notFound
        case .conflict: return TicketsCLIExit.unavailable
        default: return TicketsCLIExit.conflict
        }
    }

    /// Über den Control-Socket der App.
    static func live(_ key: String) -> TicketsOpenReply {
        let response: ChatsControlResponse
        do {
            response = try ChatsControlClient.send(method: "tickets.open", params: ["key": key])
        } catch let ChatsControlClient.ClientError.outcomeUnknown(message) {
            return .refused(exitCode: ChatsCLIExit.outcomeUnknown, message: message)
        } catch let ChatsControlClient.ClientError.appUnreachable(message), let ChatsControlClient.ClientError.protocolError(message) {
            return .refused(exitCode: TicketsCLIExit.unavailable, message: "WhisperM8 ist nicht erreichbar: \(message)")
        } catch {
            return .refused(exitCode: TicketsCLIExit.unavailable, message: "WhisperM8 ist nicht erreichbar: \(error.localizedDescription)")
        }
        guard response.ok, let result = response.result else {
            let code = response.error.flatMap { ChatsControlErrorCode(rawValue: $0.code) } ?? .internalError
            return .refused(exitCode: exitCode(for: code), message: response.error?.message ?? "Die App hat das Ticket nicht geöffnet.")
        }
        return .opened(key: result["key"]?.stringValue ?? key, title: result["title"]?.stringValue ?? "",
                       status: result["status"]?.stringValue ?? "", team: result["team"]?.stringValue ?? "",
                       project: result["project"]?.stringValue ?? "",
                       pending: result["pending"]?.boolValue ?? false)
    }
}
