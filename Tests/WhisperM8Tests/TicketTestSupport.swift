import Foundation
@testable import WhisperM8

/// Ticket-Quelle für Tests: Jede Operation ist eine Closure und wird mitgezählt.
/// Nicht gesetzte Operationen liefern einen Fehler, damit ein Test nicht
/// versehentlich etwas „erfolgreich“ tut, das er nicht vorbereitet hat.
final class TicketSourceStub: TicketSource, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []

    var onBoard: (String) async throws -> TicketBoardSnapshot = { _ in throw TicketSourceError.invalidResponse("board nicht vorbereitet") }
    var onTicket: (String) async throws -> TicketContext = { key in throw TicketSourceError.notFound(key) }
    var onLinked: (UUID) async throws -> [Ticket] = { _ in [] }
    var onCreate: (TicketDraft) async throws -> Ticket = { _ in throw TicketSourceError.invalidResponse("create nicht vorbereitet") }
    var onPerson: (String) async throws -> TicketPerson = { query in throw TicketSourceError.notFound("Person „\(query)“") }
    var onAccount: () async throws -> TicketAccount = { TicketAccount(userName: "Giuliano Costa", workspace: "Test (linear.app/test)", isAdmin: true) }
    /// Fehler für alle schreibenden Operationen (`nil` = gelingt).
    var writeError: TicketSourceError?

    /// Alle Aufrufe in Reihenfolge, z. B. `setStatus id-1 s3`.
    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    private func note(_ entry: String) {
        lock.lock(); log.append(entry); lock.unlock()
    }

    private func write(_ entry: String) throws {
        note(entry)
        if let writeError { throw writeError }
    }

    func board(team: String) async throws -> TicketBoardSnapshot { note("board \(team)"); return try await onBoard(team) }
    func ticket(key: String) async throws -> TicketContext { note("ticket \(key)"); return try await onTicket(key) }
    func tickets(linkedTo chatID: UUID) async throws -> [Ticket] { note("linked"); return try await onLinked(chatID) }
    func setStatus(ticketID: String, statusID: String) async throws { try write("setStatus \(ticketID) \(statusID)") }
    func saveLink(ticketID: String, chat: TicketChat, active: Bool, at date: Date) async throws {
        try write("saveLink \(ticketID) \(chat.shortName) \(active ? "aktiv" : "beendet")")
    }
    func removeLink(id: String) async throws { try write("removeLink \(id)") }
    func addComment(ticketID: String, body: String) async throws { try write("comment \(ticketID) \(body)") }
    func setDescription(ticketID: String, description: String) async throws { try write("description \(ticketID) \(description)") }
    func create(_ draft: TicketDraft) async throws -> Ticket { note("create \(draft.title)"); return try await onCreate(draft) }
    func assign(ticketID: String, personID: String?) async throws { try write("assign \(ticketID) \(personID ?? "niemand")") }
    func changeLabels(ticketID: String, team: String, add: [String], remove: [String]) async throws {
        try write("labels \(ticketID) +\(add.joined(separator: ",")) -\(remove.joined(separator: ","))")
    }
    func person(matching query: String) async throws -> TicketPerson { note("person \(query)"); return try await onPerson(query) }
    func account() async throws -> TicketAccount { note("account"); return try await onAccount() }
}

enum TicketFixtures {
    static let statuses: [TicketStatus] = [
        TicketStatus(id: "s0", name: "Backlog", kind: .backlog, position: 0),
        TicketStatus(id: "s1", name: "Todo", kind: .unstarted, position: 1),
        TicketStatus(id: "s2", name: "In Progress", kind: .started, position: 2),
        TicketStatus(id: "s3", name: "Merge-bereit", kind: .started, position: 2.5),
        TicketStatus(id: "s4", name: "Done", kind: .completed, position: 3),
        TicketStatus(id: "s5", name: "Canceled", kind: .canceled, position: 4),
    ]

    static func status(_ name: String) -> TicketStatus {
        statuses.first { $0.name == name }!
    }

    static func ticket(_ number: Int, status: String = "Todo", title: String? = nil, description: String = "",
                       priority: Int = 3, assignee: TicketPerson? = nil, project: String? = "Neustart",
                       labels: [String] = [], links: [TicketChatLink] = [], blocked: Bool = false) -> Ticket {
        Ticket(id: "id-\(number)", key: "WM8-\(number)", title: title ?? "Ticket \(number)", description: description,
               priority: priority, status: self.status(status), project: project, milestone: nil, assignee: assignee,
               labels: labels, links: links, isBlocked: blocked, url: "https://linear.app/x/issue/WM8-\(number)")
    }

    static func link(_ chat: UUID, active: Bool = true, id: String? = nil) -> TicketChatLink {
        TicketChatLink(id: id ?? "att-\(chat.uuidString.prefix(4))", chatID: chat, isActive: active, title: "Chat",
                       subtitle: active ? "arbeitet seit 14.11. 00:51 · WhisperM8" : "beendet am 14.11. 01:10 · WhisperM8",
                       creatorName: "Giuliano Costa")
    }

    static func snapshot(_ tickets: [Ticket], at seconds: TimeInterval = 0) -> TicketBoardSnapshot {
        TicketBoardSnapshot(team: "WM8", statuses: statuses, tickets: tickets, fetchedAt: Date(timeIntervalSince1970: seconds))
    }
}
