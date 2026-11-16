import Foundation

// Das Ticket-Board am Controller (WM8-91, Plan docs/plans/ticket-board-controller.md).
// Pur, nur Foundation: Was der Controller über das Board wissen muss und wie
// die Zeilen im Reiter „Tickets“ der Insel entstehen.

/// Was die Ticket-Ansicht gerade zeigt (WM8-91, Paket 2).
enum ControllerTicketView: String, Sendable {
    /// Noch kein Stand, kein Team, kein Zugang: nichts zu bedienen.
    case empty
    /// Spalten nach Status.
    case board
    /// Modus Liste (nach Projekt).
    case list
    /// Ticket groß, Fokus in der Liste links.
    case triage
    /// Ticket groß, Fokus auf einer Zeile unter „Chats am Ticket“.
    case chatLine
}

/// Das Board, das ein Fenster gerade zeigt. Steht im Schnappschuss des
/// Fensters nur, solange es die Tickets zeigt.
struct ControllerTicketsPlace: Equatable, Sendable {
    /// Projekt des Boards; `nil` ohne gewähltes Projekt.
    var projectID: UUID?
    /// Team-Kürzel („WM8“); `nil`, solange es nicht bekannt ist oder das
    /// Projekt kein Team hat.
    var team: String?
    /// Name des Projekts, falls es kein Team gibt.
    var projectName: String?
    var view: ControllerTicketView = .empty
    /// Auf der Chat-Zeile: Titel des Chats, zu dem Kreuz führt; `nil`, wenn
    /// der Chat nicht auf diesem Rechner läuft (dann geht „Zum Chat“ nicht).
    var chatLineTitle: String?
    /// Ein Ticket ist gewählt (Karte, Zeile oder groß).
    var hasTicket = false
    /// Das gewählte Ticket hat Chats (▶ in der Triage führt dorthin).
    var ticketHasChats = false

    /// Was Leiste und Insel nach „Tickets · “ nennen.
    var label: String? { team ?? projectName }
}

/// Zusammenhang „Ticket-Board“: Das Fenster zeigt die Tickets statt der
/// Chats. Kein Chat ist dann Ziel einer Eingabe (`withChatsHidden`); was im
/// Chat sendet, bestätigt, abbricht oder diktiert, tut hier nichts.
struct ControllerTicketState: Equatable, Sendable {
    var place: ControllerTicketsPlace
    /// Liste links (Seitenleiste) oder das Board.
    var area: ControllerFocusArea = .content
    /// Ziel von L2 getippt; `nil`, wenn es keinen vorigen Ort gibt.
    var backTarget: ControllerBackTarget?
}

/// Ein Board im Reiter „Tickets“ der Insel: je eingerichtetem Team mit
/// Projekt eine Zeile. Gebaut im Ereignis-Pfad, wenn die Insel aufgeht.
struct ControllerTicketBoardChoice: Equatable, Sendable, Identifiable {
    /// Projekt, dessen Board die Zeile öffnet. Beim Team des aktuellen
    /// Projekts ist das das aktuelle Projekt selbst.
    var id: UUID
    var team: String
    var projectName: String
    var colorHex: String
    /// Tickets, die auf den Nutzer warten; `nil`, solange kein Stand des
    /// Boards geladen ist (die App fragt dafür nicht eigens nach).
    var waitingCount: Int?
    /// Team des Projekts, in dem man gerade ist („hier“).
    var isHere: Bool
    /// Dieses Board ist gerade offen („jetzt“).
    var isCurrent: Bool
    /// Zuletzt gezeigtes Board dieses Fensters („vorher“).
    var isPrevious: Bool = false
}

/// Ein Team aus der Einrichtung, wie die Insel es braucht.
struct ControllerTicketTeam: Equatable, Sendable {
    var team: String
    /// Projekt, über das das Board dieses Teams aufgeht.
    var projectID: UUID
    var projectName: String
    var colorHex: String
}

/// Was der Reiter „Tickets“ zeigt.
struct ControllerTicketBoards: Equatable, Sendable {
    var rows: [ControllerTicketBoardChoice] = []
    /// Projekt, in dem man ist, ohne Team: Name für den Hinweis
    /// „… hat kein Team“; `nil`, wenn es ein Team hat oder kein Projekt gewählt ist.
    var hereWithoutTeam: String?
    /// Das Fenster zeigt gerade die Tickets.
    var inTickets = false

    /// Zeilen in fester Reihenfolge: zuerst das Board des aktuellen Projekts
    /// („hier“, im Board „jetzt“), gleich darunter das zuletzt gezeigte
    /// („vorher“), dann die übrigen Teams nach Kürzel.
    ///
    /// - Parameters:
    ///   - teams: eingerichtete Teams mit Projekt (eines je Team).
    ///   - hereProjectID: das Projekt, in dem man gerade ist.
    ///   - hereTeam: dessen Team, falls bekannt.
    ///   - shownProjectID: Projekt des offenen Boards (nur im Ticket-Modus).
    ///   - lastProjectID: zuletzt gezeigtes Board dieses Fensters.
    static func make(
        teams: [ControllerTicketTeam], hereProjectID: UUID?, hereProjectName: String?, hereTeam: String?,
        inTickets: Bool, lastProjectID: UUID?, teamOfProject: (UUID) -> String?, waiting: (String) -> Int?
    ) -> ControllerTicketBoards {
        func same(_ lhs: String?, _ rhs: String) -> Bool { lhs?.caseInsensitiveCompare(rhs) == .orderedSame }
        let lastTeam = lastProjectID.flatMap(teamOfProject)
        var rows = teams.sorted { $0.team.localizedStandardCompare($1.team) == .orderedAscending }.map { team in
            let here = same(hereTeam, team.team)
            // „hier“ öffnet das Board des aktuellen Projekts selbst (ein
            // Arbeitsordner hat dasselbe Team, aber eine eigene Wurzel).
            // Ebenso „vorher“: das zuletzt gezeigte Board selbst.
            let previous = !here && same(lastTeam, team.team)
            let id = here ? (hereProjectID ?? team.projectID) : (previous ? (lastProjectID ?? team.projectID) : team.projectID)
            return ControllerTicketBoardChoice(
                id: id, team: team.team, projectName: team.projectName, colorHex: team.colorHex,
                waitingCount: waiting(team.team), isHere: here, isCurrent: here && inTickets, isPrevious: previous)
        }
        if let index = rows.firstIndex(where: \.isPrevious) { rows.insert(rows.remove(at: index), at: 0) }
        if let index = rows.firstIndex(where: \.isHere) { rows.insert(rows.remove(at: index), at: 0) }
        let withoutTeam = hereProjectID != nil && hereTeam == nil ? hereProjectName : nil
        return ControllerTicketBoards(rows: rows, hereWithoutTeam: withoutTeam, inTickets: inTickets)
    }
}

/// Eintrag „Ticket-Board WM8“ im Options-Menü eines Chats: das Board des
/// Projekts dieses Chats.
struct ControllerTicketBoardTarget: Equatable, Sendable {
    var projectID: UUID
    var team: String
}

/// Was der Controller im Ticket-Board auslöst. Nichts davon schreibt nach
/// Linear oder in einen Chat; „Zum Chat“ wechselt nur sichtbar dorthin.
enum ControllerTicketCommand: Equatable, Sendable {
    /// Stick, Steuerkreuz: Auswahl, Liste der Triage, Chat-Zeile.
    case move(ControllerDirection)
    /// Kreuz: Ticket groß bzw. auf der Chat-Zeile „Zum Chat“.
    case open
    /// Kreis in der Triage: zurück zum Board, von der Chat-Zeile in die Liste.
    case back
    /// L1/R1: voriges oder nächstes Ticket.
    case adjacent(Int)
    case copyLink
    case openInLinear
    /// R3: wie ↻ im Kopf, einmal je Druck.
    case refresh
    /// Rechter Stick in der Triage: Beschreibung und Verlauf blättern.
    case scroll(lines: Int)
    /// Menü: Filter „Wartet auf mich“ an/aus, Liste kopieren.
    case toggleWaitingFilter
    case copyList
    /// Menü „Zum Chat ›“: dieser Chat am gewählten Ticket.
    case goToChat(UUID)
    /// R2 ohne Board-Chat (E4): „geht nicht“ und einmal der Grund in der
    /// Leiste. Kein Diktat, nichts an einen Chat.
    case dictationUnavailable
}

/// Was ein Befehl bewirkt hat.
enum ControllerTicketOutcome: Equatable, Sendable {
    case done
    /// Am Rand oder ohne Wirkung, still (etwa ▲ auf der obersten Karte).
    case nothing
    /// Geht hier nicht: „geht nicht“.
    case rejected
    /// Links aus der ersten Spalte oder der Liste: weiter in die Seitenleiste.
    case leftEdge
}

/// Angaben für die Menü-Karte am Ticket (Options im Board).
struct ControllerTicketMenuInfo: Equatable, Sendable {
    struct Chat: Equatable, Sendable {
        var id: UUID
        var title: String
    }

    /// Ticket-Nummer für die Überschrift; `nil` ohne gewähltes Ticket.
    var key: String?
    /// Chats am Ticket, die auf diesem Rechner laufen.
    var chats: [Chat] = []
    var hasURL = false
    var waitingFilterOn = false
}

/// Kurze Bestätigung in der Leiste nach einer Taste im Ticket-Board.
enum ControllerTicketNotice: String, Sendable {
    case linkCopied, listCopied, refreshing, dictationNeedsBoardChat
}
