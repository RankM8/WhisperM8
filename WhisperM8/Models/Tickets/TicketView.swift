import Foundation

// MARK: - Gespeicherte Ansichten aus dem Ticket-Werkzeug (WM8-125)

/// Wonach eine Ansicht ihre Tickets gruppiert. Was WhisperM8 nicht kennt
/// (Zyklus, Meilenstein, Team …), zeigt die Liste nach Status und nennt den
/// eigentlichen Namen (`unsupported`).
enum TicketViewGrouping: Equatable {
    case status
    case project
    case priority
    case assignee
    case label
    case none
    case unsupported(String)

    /// Werte, wie Linear sie in `viewPreferencesValues.issueGrouping` führt.
    init(linear raw: String?) {
        switch raw ?? "workflowState" {
        case "workflowState": self = .status
        case "project": self = .project
        case "priority": self = .priority
        case "assignee": self = .assignee
        case "label", "labels": self = .label
        case "noGrouping", "none": self = .none
        case let other: self = .unsupported(other)
        }
    }
}

/// Wonach innerhalb einer Gruppe sortiert wird. Nur, was das Board am Ticket
/// hat; alles andere sortiert nach Priorität.
enum TicketViewOrdering: Equatable {
    case priority
    case updated

    init(linear raw: String?) {
        self = raw == "updatedAt" ? .updated : .priority
    }
}

/// Eine gespeicherte Ansicht (Linear: `CustomView`), als Reiter oben im Board.
/// Gefiltert wird bei Linear; WhisperM8 übernimmt nur Gruppierung, Sortierung
/// und ob Unteraufgaben unter ihrem Eltern-Ticket stehen.
struct TicketView: Equatable, Identifiable {
    var id: String
    var name: String
    /// Team der Ansicht; `nil` gilt für den ganzen Workspace.
    var teamKey: String?
    var grouping: TicketViewGrouping
    var ordering: TicketViewOrdering
    var showsSubIssues: Bool
    var url: String?
}

/// Die Reiter eines Workspaces und welcher davon zuerst steht.
struct TicketViewCatalog: Equatable {
    var views: [TicketView]
    /// Standard-Reiter; `nil` ohne Ansichten.
    var defaultID: String?

    static let empty = TicketViewCatalog(views: [], defaultID: nil)

    /// Namensanfänge der persönlichen „Als Nächstes“-Ansicht.
    static let nextPrefixes = ["als nächstes", "next", "up next"]

    /// Reiter sind die Favoriten des Nutzers in ihrer Reihenfolge (Entscheidung
    /// Giuliano, 16.11.2026). Standard ist die Ansicht „Als Nächstes: <Vorname>“;
    /// ist sie kein Favorit, steht sie trotzdem vorn. Ohne sie gilt der erste
    /// Favorit.
    /// - Parameters:
    ///   - favorites: Favoriten in der Reihenfolge des Werkzeugs, nur Ansichten über Tickets.
    ///   - candidates: weitere Ansichten, die als Standard in Frage kommen.
    ///   - viewerName: voller Name des Nutzers; zählt wird der Vorname.
    static func make(favorites: [TicketView], candidates: [TicketView], viewerName: String) -> TicketViewCatalog {
        var seen = Set<String>()
        var views = favorites.filter { seen.insert($0.id).inserted }
        let firstName = viewerName.split(separator: " ").first.map { $0.lowercased() } ?? ""
        func isPersonalNext(_ view: TicketView) -> Bool {
            let name = view.name.lowercased()
            guard nextPrefixes.contains(where: { name.hasPrefix($0) }) else { return false }
            return !firstName.isEmpty && name.contains(firstName)
        }
        if let personal = views.first(where: isPersonalNext) {
            return TicketViewCatalog(views: views, defaultID: personal.id)
        }
        if let personal = candidates.first(where: isPersonalNext) {
            views.insert(personal, at: 0)
            return TicketViewCatalog(views: views, defaultID: personal.id)
        }
        return TicketViewCatalog(views: views, defaultID: views.first?.id)
    }
}
