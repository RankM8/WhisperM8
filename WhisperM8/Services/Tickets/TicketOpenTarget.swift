import Foundation

// MARK: - Ticket von außen öffnen (WM8-131, pur)

/// `whisperm8 tickets open <Ticket>`: Welches Board gehört zum Ticket? Das
/// Team steckt in der Nummer, das Projekt folgt aus der Einrichtung
/// (`tickets.json`, Ordner → Team) und den Projekten der App. Pur bis auf
/// `TicketTeamDirectory.resolve`, das für Arbeitsordner neben dem Projekt
/// `.git` liest: nicht auf dem Main Thread aufrufen.
enum TicketOpenTarget {
    /// Projekt der App, dessen Board das Ticket zeigt.
    struct Board: Equatable, Sendable {
        var key: String
        var team: String
        var workspace: String
        var projectID: UUID
        var projectName: String
        /// Pfad, wie die App ihn führt; daran erkennt das Board sein Projekt.
        var projectPath: String
    }

    enum Failure: Error, Equatable {
        case invalidKey(String)
        /// Das Team kennt die Einrichtung nicht.
        case unknownTeam(String)
        /// Das Team hat keinen Ordner, oder keiner seiner Ordner ist ein Projekt der App.
        case noProject(team: String)
        /// Das Team liegt in keinem eingerichteten Workspace (mehrere Workspaces, Team ohne Zuordnung).
        case noWorkspace(team: String)

        /// Meldung für die Kommandozeile.
        var message: String {
            switch self {
            case .invalidKey(let raw):
                return "„\(raw)“ ist keine Ticket-Nummer (erwartet z. B. ABC-12 oder die Adresse aus Linear)."
            case .unknownTeam(let team):
                return "Team \(team) ist nicht eingerichtet. Einrichten: whisperm8 tickets setup --team \(team) --project <Ordner>"
            case .noProject(let team):
                return "Zu Team \(team) gehört kein Projekt der App. Zuordnen: whisperm8 tickets setup --team \(team) --project <Ordner>"
            case .noWorkspace(let team):
                return "Team \(team) gehört zu keinem eingerichteten Workspace. Zuordnen: whisperm8 tickets setup --team \(team) --workspace <Kürzel>"
            }
        }
    }

    /// Ticket-Nummer aus der Eingabe: `wm8-12`, `WM8-12` oder die Adresse aus
    /// Linear (`https://linear.app/<workspace>/issue/WM8-12/…`). `nil`, wenn
    /// darin keine Nummer steht.
    static func key(fromInput raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isKey(trimmed) { return trimmed.uppercased() }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "issue"), index + 1 < parts.count, isKey(parts[index + 1]) else { return nil }
        return parts[index + 1].uppercased()
    }

    private static func isKey(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z][A-Za-z0-9]*-[0-9]+$"#, options: .regularExpression) != nil
    }

    /// Board zum Ticket. Je Team gilt das Projekt, dessen Ordner in der
    /// Einrichtung steht, sonst das erste Projekt des Teams (dieselbe Regel wie
    /// der Reiter „Tickets“ des Controllers).
    static func resolve(key: String, config: TicketConfig,
                        projects: [TicketTeamDirectory.Project]) -> Result<Board, Failure> {
        let team = TicketConfig.team(ofKey: key)
        guard !team.isEmpty, config.knows(team: team) else { return .failure(.unknownTeam(team)) }
        guard let workspace = config.workspace(forTeam: team) else { return .failure(.noWorkspace(team: team)) }
        let resolved = TicketTeamDirectory.resolve(config: config, projects: projects)
        guard let choice = resolved.teams.first(where: { $0.team.caseInsensitiveCompare(team) == .orderedSame }),
              let project = projects.first(where: { $0.id == choice.projectID })
        else { return .failure(.noProject(team: team)) }
        return .success(Board(key: key, team: team.uppercased(), workspace: workspace, projectID: project.id,
                              projectName: project.name, projectPath: project.path))
    }
}
