import Foundation

/// Welches Projekt der App zu welchem Team gehört, als Zwischenspeicher für
/// den Controller (WM8-91): Insel („Wohin“, Reiter „Tickets“), Leiste
/// („Tickets · WM8“) und Options-Menü lesen hier, nie von Disk.
///
/// Die Einrichtung (`tickets.json`) und die Zuordnung eines Arbeitsordners
/// zu seinem Haupt-Repo (liest `.git`) laufen abseits des Main Threads.
/// Angestoßen wird beim Erscheinen eines Fensters, beim Umschalten auf die
/// Tickets und beim Öffnen von „Wohin“; bis zum ersten Ergebnis zeigen die
/// Stellen nur „Tickets“ ohne Kürzel. Kosten: eine kleine JSON-Datei und je
/// Projekt höchstens ein Blick in `.git`, einige Millisekunden im Hintergrund.
@MainActor
final class TicketTeamDirectory {
    static let shared = TicketTeamDirectory(load: { TicketConfigStore.live.load() })

    struct Project: Equatable, Sendable {
        var id: UUID
        var path: String
        var name: String
        var colorHex: String
    }

    struct Resolved: Equatable, Sendable {
        var teamByProjectID: [UUID: String] = [:]
        /// Ein Eintrag je Team mit Projekt in der App.
        var teams: [ControllerTicketTeam] = []
    }

    private(set) var resolved = Resolved()
    private let load: @Sendable () -> TicketConfig
    private var isRefreshing = false
    private var pending: [Project]?

    init(load: @escaping @Sendable () -> TicketConfig) {
        self.load = load
    }

    func team(of projectID: UUID?) -> String? {
        projectID.flatMap { resolved.teamByProjectID[$0] }
    }

    /// Liest die Einrichtung neu, im Hintergrund. Läuft schon ein Abgleich,
    /// folgt genau einer mit dem neuesten Stand danach.
    func refresh(projects: [Project], completion: (@MainActor () -> Void)? = nil) {
        guard !isRefreshing else {
            pending = projects
            return
        }
        isRefreshing = true
        let load = load
        Task { [weak self] in
            let fresh = await TicketBlockingWork.run { Self.resolve(config: load(), projects: projects) }
            guard let self else { return }
            if self.resolved != fresh { self.resolved = fresh }
            self.isRefreshing = false
            completion?()
            if let next = self.pending {
                self.pending = nil
                self.refresh(projects: next)
            }
        }
    }

    /// Pur bis auf `TicketConfig.team(forDirectory:)`, das für Arbeitsordner
    /// neben dem Projekt `.git` liest: nicht auf dem Main Thread aufrufen.
    nonisolated static func resolve(config: TicketConfig, projects: [Project]) -> Resolved {
        var result = Resolved()
        for project in projects {
            if let team = config.team(forDirectory: project.path) { result.teamByProjectID[project.id] = team }
        }
        // Je Team das Projekt, dessen Ordner in der Einrichtung steht; sonst
        // das erste Projekt dieses Teams (etwa ein Arbeitsordner).
        let teams = Set(config.teamsByProjectPath.values.map { $0.uppercased() })
        for team in teams.sorted() {
            let paths = Set(config.projectPaths(forTeam: team).map { TicketConfig.normalized($0).lowercased() })
            let members = projects.filter { result.teamByProjectID[$0.id]?.caseInsensitiveCompare(team) == .orderedSame }
            guard let project = members.first(where: { paths.contains(TicketConfig.normalized($0.path).lowercased()) })
                ?? members.first else { continue }
            result.teams.append(ControllerTicketTeam(
                team: team, projectID: project.id, projectName: project.name, colorHex: project.colorHex))
        }
        return result
    }
}
