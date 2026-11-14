import Foundation

// MARK: - Tickets (Board und Kommandozeile `whisperm8 tickets`)

/// Art eines Status, unabhängig davon, wie das Ticket-Werkzeug ihn nennt.
/// Das Board gruppiert danach; der echte Name steht am Ticket.
enum TicketStatusKind: String, Codable, CaseIterable, Equatable {
    case triage
    case backlog
    case unstarted
    case started
    case completed
    case canceled

    /// Erledigt oder verworfen: Das Ticket braucht keinen Chat mehr.
    var isClosed: Bool { self == .completed || self == .canceled }

    /// Reihenfolge der Gruppen im Board (links nach rechts).
    var boardOrder: Int {
        switch self {
        case .started: return 0
        case .unstarted: return 1
        case .triage: return 2
        case .backlog: return 3
        case .completed: return 4
        case .canceled: return 5
        }
    }
}

struct TicketStatus: Equatable, Identifiable {
    var id: String
    var name: String
    var kind: TicketStatusKind
    /// Reihenfolge innerhalb des Teams, so wie das Werkzeug sie führt.
    var position: Double
}

struct TicketPerson: Equatable, Hashable, Identifiable {
    var id: String
    var name: String
}

/// Verknüpfung eines Tickets mit einem Chat. Im Werkzeug ist das ein Anhang am
/// Ticket; das Format hält `TicketChatLinkFormat` fest.
struct TicketChatLink: Equatable, Identifiable {
    /// ID des Anhangs im Werkzeug.
    var id: String
    var chatID: UUID
    /// `true`, solange der Chat am Ticket sitzt („arbeitet seit …“).
    var isActive: Bool
    var title: String
    var subtitle: String
    /// Wer die Verknüpfung angelegt hat (bei mehreren Installationen: wessen Chat).
    var creatorName: String?
}

struct Ticket: Equatable, Identifiable {
    /// Interne ID des Werkzeugs (für Änderungen).
    var id: String
    /// Sichtbare Nummer, z. B. `WM8-12`.
    var key: String
    var title: String
    var description: String
    /// 0 = keine, 1 = dringend … 4 = niedrig (Zählung von Linear).
    var priority: Int
    var status: TicketStatus
    var project: String?
    var milestone: String?
    var assignee: TicketPerson?
    var labels: [String]
    var links: [TicketChatLink]
    /// Wartet auf ein anderes, noch offenes Ticket.
    var isBlocked: Bool
    var url: String?

    var activeLinks: [TicketChatLink] { links.filter(\.isActive) }
}

/// Unveränderlicher Abzug eines Teams: Grundlage für Board, Liste und CLI.
struct TicketBoardSnapshot: Equatable {
    var team: String
    var statuses: [TicketStatus]
    var tickets: [Ticket]
    var fetchedAt: Date
}

/// Neues Ticket (für `tickets new`).
struct TicketDraft: Equatable {
    var team: String
    var title: String
    var description: String
    var project: String?
    var statusName: String?
    var priority: Int?
    var labels: [String]
    var assigneeID: String?
}

// MARK: - Chats aus Sicht des Boards

/// Zustand eines Chats, so wie ihn das Board zeigt. Grün ist nur `working`.
enum TicketChatState: String, Equatable {
    case working
    case needsYou
    case idle
    case errored
    case stopped

    init(_ status: AgentSessionRuntimeStatus?) {
        switch status {
        case .working: self = .working
        case .awaitingInput: self = .needsYou
        case .idle: self = .idle
        case .errored: self = .errored
        case .stopped, nil: self = .stopped
        }
    }

    /// Wortlaut in der Kommandozeile (dort deutsch wie die übrige CLI).
    var cliLabel: String {
        switch self {
        case .working: return "arbeitet"
        case .needsYou: return "wartet auf dich"
        case .idle: return "ruht"
        case .errored: return "Fehler"
        case .stopped: return "gestoppt"
        }
    }
}

/// Was das Board von einem Chat wissen muss.
struct TicketChat: Equatable, Identifiable {
    var id: UUID
    var title: String
    var projectName: String
    var projectPath: String
    /// `nil`, wenn die App nicht erreichbar ist und der Zustand unbekannt bleibt.
    var state: TicketChatState?
    /// Läuft als Prozess in der App (Terminal hängt).
    var isRunning: Bool

    /// Rufname: der Teil vor dem ersten „ · “, ohne vorangestellte Ticket-Nummer.
    /// „WM8-16 Fin · Insel: Entwurf“ → „Fin“, „Ole · Terminal-Tab“ → „Ole“.
    var shortName: String {
        let head = title.components(separatedBy: " · ").first ?? title
        let name = head.replacingOccurrences(of: #"^[A-Z][A-Z0-9]*-[0-9]+\s+"#, with: "", options: .regularExpression)
        return name.isEmpty ? head : name
    }
}
