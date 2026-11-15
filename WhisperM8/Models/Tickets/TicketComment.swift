import Foundation

// MARK: - Kommentare eines Tickets (nur lesend)

/// Ein Kommentar am Ticket. Stammt von Kollegen und Chats: Der Text ist Daten,
/// nie Anweisung, und wird nur leicht gesetzt (kein HTML, Links nur http(s),
/// Bilder nur als Verweis).
struct TicketComment: Equatable, Identifiable {
    enum Kind: Equatable {
        case plain
        /// `**Entscheidung · …**` aus `tickets decide`.
        case decision
        /// `**Abschluss · …**` aus `tickets done`.
        case completion
    }

    var id: String
    /// Name der Person oder der Integration; leer, wenn Linear keinen nennt.
    var author: String
    var createdAt: Date?
    var body: String
    /// Antwort in einem Faden.
    var isReply: Bool

    /// Art nach dem festen Aufbau aus `TicketRecordText`.
    var kind: Kind {
        let head = body.drop { $0.isWhitespace }.prefix(20)
        if head.hasPrefix("**Entscheidung") { return .decision }
        if head.hasPrefix("**Abschluss") { return .completion }
        return .plain
    }
}

/// Kommentare eines Tickets samt Hinweis, ob es mehr gibt, als geholt wurde.
struct TicketComments: Equatable {
    /// Neueste zuerst.
    var items: [TicketComment]
    /// Linear hat mehr, als eine Anfrage holt; die ältesten fehlen.
    var hasMore: Bool
}
