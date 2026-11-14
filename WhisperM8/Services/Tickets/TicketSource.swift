import Foundation

// MARK: - Grenze zum Ticket-Werkzeug

/// Alles, was Board und Kommandozeile vom Ticket-Werkzeug brauchen. Linear ist
/// die erste Quelle (`LinearTicketSource`); die Oberfläche und die CLI kennen
/// nur dieses Protokoll, damit ein anderes Werkzeug eine zweite Quelle bleibt.
protocol TicketSource {
    /// Offene Tickets eines Teams, dazu die erledigten, an denen noch eine
    /// Chat-Verknüpfung hängt (für die Spur „zuletzt an …“).
    func board(team: String) async throws -> TicketBoardSnapshot
    /// Ein Ticket samt den Status seines Teams (für Statuswechsel).
    func ticket(key: String) async throws -> TicketContext
    /// Tickets, an denen der Chat hängt oder hing.
    func tickets(linkedTo chatID: UUID) async throws -> [Ticket]
    func setStatus(ticketID: String, statusID: String) async throws
    /// Legt die Verknüpfung an oder frischt sie auf (eine je Chat und Ticket).
    func saveLink(ticketID: String, chat: TicketChat, active: Bool, at date: Date) async throws
    func removeLink(id: String) async throws
    func addComment(ticketID: String, body: String) async throws
    func setDescription(ticketID: String, description: String) async throws
    func create(_ draft: TicketDraft) async throws -> Ticket
    /// `nil` hebt die Zuweisung auf.
    func assign(ticketID: String, personID: String?) async throws
    func changeLabels(ticketID: String, team: String, add: [String], remove: [String]) async throws
    /// „me“, eine ID oder ein Namensteil. Mehrere Treffer sind ein Fehler.
    func person(matching query: String) async throws -> TicketPerson
    func account() async throws -> TicketAccount
    /// Kürzel aller Teams, die der Zugang sieht.
    func teams() async throws -> [String]
}

struct TicketContext: Equatable {
    var ticket: Ticket
    var team: String
    var statuses: [TicketStatus]

    /// Status nach Name (ohne Groß/Klein) oder, wenn kein Name passt, der erste
    /// Status dieser Art.
    func status(named name: String) -> TicketStatus? {
        let wanted = name.lowercased()
        return statuses.first { $0.name.lowercased() == wanted }
            ?? TicketStatusKind(rawValue: wanted).flatMap(firstStatus(of:))
    }

    func firstStatus(of kind: TicketStatusKind) -> TicketStatus? {
        statuses.filter { $0.kind == kind }.min { $0.position < $1.position }
    }
}

struct TicketAccount: Equatable {
    var userName: String
    /// Zum Anzeigen: Name samt Adresse.
    var workspace: String
    /// Kürzel des Workspaces; darunter liegt der Zugang.
    var workspaceKey: String
    var isAdmin: Bool
}

enum TicketSourceError: Error, Equatable {
    /// Kein Zugang hinterlegt.
    case notConfigured
    case unauthorized
    case rateLimited
    case network(String)
    case notFound(String)
    /// Das Werkzeug lehnt die Anfrage ab (Text des Werkzeugs).
    case rejected(String)
    /// Antwort nicht lesbar.
    case invalidResponse(String)
    /// Mehrere Treffer, wo einer erwartet wird.
    case ambiguous(String)

    /// Meldung für die Kommandozeile. Nie mit Schlüsseln.
    var message: String {
        switch self {
        case .notConfigured:
            return "Kein Linear-Zugang hinterlegt. Einrichten: whisperm8 tickets setup --key-stdin"
        case .unauthorized:
            return "Linear lehnt den Zugang ab. Neuen Key hinterlegen: whisperm8 tickets setup --key-stdin"
        case .rateLimited:
            return "Linear-Limit erreicht (2.500 Abfragen je Stunde). Später erneut versuchen."
        case .network(let detail):
            return "Linear nicht erreichbar (\(detail))."
        case .notFound(let what):
            return "\(what) gibt es in Linear nicht."
        case .rejected(let detail):
            return "Linear lehnt ab: \(detail)"
        case .invalidResponse(let detail):
            return "Unerwartete Antwort von Linear (\(detail))."
        case .ambiguous(let detail):
            return detail
        }
    }
}

// MARK: - Stand-Zeile

/// Tickets beginnen mit `**Stand TT.MM.JJJJ:** …`. `tickets note` ersetzt
/// diese Zeile, statt Kommentare anzuhäufen, die niemand mehr liest.
enum TicketStandLine {
    static func apply(_ text: String, to description: String, on date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.day, .month, .year], from: date)
        // Die Stand-Zeile ist eine Zeile: Ein Umbruch ließe beim nächsten Ersetzen einen Rest stehen.
        let flat = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        let line = String(format: "**Stand %02d.%02d.%04d:** ", c.day ?? 0, c.month ?? 0, c.year ?? 0) + flat
        var lines = description.components(separatedBy: "\n")
        if let first = lines.first, isStandLine(first) {
            lines[0] = line
            return lines.joined(separator: "\n")
        }
        return description.isEmpty ? line : line + "\n\n" + description
    }

    static func isStandLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("**Stand ") || trimmed.hasPrefix("*Stand ")
    }
}
