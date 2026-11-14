import Foundation
import Observation

// MARK: - Einstellungen › Tickets: Abhängigkeiten

/// Ein Projekt der App, das sich einem Team zuordnen lässt.
struct TicketProjectChoice: Identifiable, Hashable {
    var name: String
    var path: String
    var id: String { path }
}

/// Was die Seite von außen braucht. Snapshots und Tests setzen eigene Werte.
///
/// Alles außer `projects` und `chooseFolder` läuft abseits des Main Threads:
/// Der Schlüsselbund wird über einen blockierenden Kindprozess gelesen, und ein
/// Schlüsselbund-Dialog darf die App nie einfrieren.
struct TicketsSettingsDependencies {
    var loadConfig: @Sendable () -> TicketConfig
    /// Wie `loadConfig`, wirft aber bei einer vorhandenen, unlesbaren Datei:
    /// Auf ihr wird nichts geändert, sonst wäre ihr Inhalt verloren.
    var loadConfigForChange: @Sendable () throws -> TicketConfig
    var saveConfig: @Sendable (TicketConfig) throws -> Void
    var hasKey: @Sendable (_ workspace: String) -> Bool
    /// `false`, wenn der Eintrag danach nicht lesbar ist.
    var storeKey: @Sendable (_ workspace: String, _ key: String) -> Bool
    /// `false`, wenn der Eintrag danach noch da ist.
    var deleteKey: @Sendable (_ workspace: String) -> Bool
    /// Fragt Linear, wem ein noch nicht gespeicherter Key gehört.
    var account: @Sendable (_ key: String) async -> Result<TicketAccount, TicketSourceError>
    var teams: @Sendable (_ workspace: String) async -> Result<[String], TicketSourceError>
    var projects: @MainActor () -> [TicketProjectChoice]
    /// Ordner-Auswahl für ein Projekt, das die App noch nicht kennt.
    var chooseFolder: @MainActor () -> String?

    static let live: TicketsSettingsDependencies = {
        let store = TicketConfigStore.live
        return TicketsSettingsDependencies(
            loadConfig: { store.load() },
            loadConfigForChange: { try store.loadForChange() },
            saveConfig: { try store.save($0) },
            hasKey: { workspace in
                TicketCredentialCache.shared.value(for: workspace) { TicketCredentialStore.live.read(workspace) } != nil
            },
            storeKey: { TicketCredentialStore.live.write($0, $1) },
            deleteKey: { workspace in
                TicketCredentialStore.live.delete(workspace)
                return TicketCredentialStore.live.read(workspace) == nil
            },
            account: { key in await result { try await LinearTicketSource(client: .live(key: key)).account() } },
            teams: { workspace in await result { try await LinearTicketSource(client: .live(workspace: workspace)).teams() } },
            projects: {
                AgentWorkspaceUIModel.shared.workspace.projects
                    .map { TicketProjectChoice(name: $0.name, path: TicketConfig.normalized($0.path)) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            },
            chooseFolder: { TicketsSettingsFolderPicker.choose() }
        )
    }()

    private static func result<T>(_ work: () async throws -> T) async -> Result<T, TicketSourceError> {
        do {
            return .success(try await work())
        } catch let error as TicketSourceError {
            return .failure(error)
        } catch {
            return .failure(.network("Netzfehler"))
        }
    }
}

// MARK: - Modell

/// Zustand der Seite „Tickets“: eingerichtete Workspaces, ihre Teams und die
/// Zuordnung Projektordner → Team. Schreibt dieselbe `tickets.json` und
/// dieselben Schlüsselbund-Einträge wie `whisperm8 tickets setup`, nach
/// denselben Regeln: Ein Key liegt unter dem Workspace, den Linear zu ihm
/// nennt, und ein Team-Kürzel gehört zu genau einem Workspace. Anders als die
/// Kommandozeile kann die Seite einen Key und eine Zuordnung auch entfernen.
@MainActor
@Observable
final class TicketsSettingsModel {
    struct Workspace: Identifiable, Equatable {
        var name: String
        var hasKey: Bool
        /// Teams, die der Zugang sieht; leer ohne Key oder bei einem Fehler.
        var teams: [String] = []
        /// Fertig übersetzter Satz, wenn der Zugang nicht geht.
        var problem: String?
        var id: String { name }
    }

    struct Mapping: Identifiable, Equatable {
        var path: String
        var team: String
        /// `nil`, wenn das Team keinem Workspace zugeordnet ist.
        var workspace: String?
        /// Der Zugang sieht das Team in seinem Workspace nicht (mehr): gelöscht, umbenannt oder ohne Zugriff.
        var teamMissing = false
        var id: String { path }
    }

    /// Ein Team der Einrichtung ohne Ordner, das sein Workspace nicht (mehr) kennt.
    struct StaleTeam: Identifiable, Equatable {
        var team: String
        var workspace: String
        var id: String { team }
    }

    struct TeamChoice: Identifiable, Hashable {
        var team: String
        var workspace: String
        var id: String { "\(workspace)/\(team)" }
    }

    enum Notice: Equatable {
        case saved(String)
        case failed(String)
    }

    private(set) var workspaces: [Workspace]
    private(set) var mappings: [Mapping]
    private(set) var staleTeams: [StaleTeam]
    private(set) var projects: [TicketProjectChoice]
    private(set) var isSavingKey = false
    private(set) var keyNotice: Notice?
    private(set) var mappingProblem: String?

    @ObservationIgnored private let dependencies: TicketsSettingsDependencies
    /// Zählt die Ladevorgänge. Nur der jüngste darf sein Ergebnis eintragen,
    /// und ein überholter fragt nicht weiter.
    @ObservationIgnored private var loadGeneration = 0

    init(dependencies: TicketsSettingsDependencies, workspaces: [Workspace] = [], mappings: [Mapping] = [],
         staleTeams: [StaleTeam] = [], projects: [TicketProjectChoice] = []) {
        self.dependencies = dependencies
        self.workspaces = workspaces
        self.mappings = mappings
        self.staleTeams = staleTeams
        self.projects = projects
    }

    /// Teams aller Workspaces mit Zugang, für die Auswahl beim Zuordnen.
    var teamChoices: [TeamChoice] {
        workspaces.flatMap { workspace in workspace.teams.map { TeamChoice(team: $0, workspace: workspace.name) } }
    }

    /// Steht etwas in der Einrichtung, das sein Workspace nicht (mehr) kennt?
    var hasMissingTeams: Bool {
        !staleTeams.isEmpty || mappings.contains(where: \.teamMissing)
    }

    /// Fehlt das Team in seinem Workspace? Ein Ja gibt es nur, wenn dessen
    /// Team-Liste sicher vorliegt: mit Key, ohne Störung und nicht an der Grenze
    /// der Abfrage abgeschnitten. Im Zweifel gilt ein Team als vorhanden.
    nonisolated static func isMissing(team: String, in workspace: Workspace?) -> Bool {
        guard let workspace, workspace.hasKey, workspace.problem == nil,
              workspace.teams.count < LinearTicketSource.teamListLimit else { return false }
        return !workspace.teams.contains { $0.caseInsensitiveCompare(team) == .orderedSame }
    }

    /// Projekte der App, die noch keinem Team zugeordnet sind.
    var unmappedProjects: [TicketProjectChoice] {
        let mapped = Set(mappings.map { $0.path.lowercased() })
        return projects.filter { !mapped.contains($0.path.lowercased()) }
    }

    /// Liest Einrichtung, Schlüsselbund und die Teams je Workspace. Nur
    /// aufrufen, wenn der Schalter an ist: Aus heißt, die App fragt weder den
    /// Schlüsselbund noch Linear.
    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        /// Überholt (neueres Laden, `stop()`) oder abgebrochen: nicht weiter fragen.
        func isCurrent() -> Bool { generation == loadGeneration && !Task.isCancelled }

        let deps = dependencies
        projects = deps.projects()
        let config = await TicketBlockingWork.run { deps.loadConfig() }
        var loaded: [Workspace] = []
        for name in config.knownWorkspaces {
            guard isCurrent() else { return }
            var workspace = Workspace(name: name, hasKey: await TicketBlockingWork.run { deps.hasKey(name) })
            if workspace.hasKey {
                guard isCurrent() else { return }
                switch await Self.offMain({ await deps.teams(name) }) {
                case .success(let teams): workspace.teams = teams.sorted()
                case .failure(let error): workspace.problem = error.userText
                }
            }
            loaded.append(workspace)
        }
        guard isCurrent() else { return }
        workspaces = loaded
        let byName = Dictionary(loaded.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        mappings = config.teamsByProjectPath
            .map { path, team in
                let workspace = config.workspace(forTeam: team)
                return Mapping(path: path, team: team, workspace: workspace,
                               teamMissing: Self.isMissing(team: team, in: workspace.flatMap { byName[$0] }))
            }
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        // Teams mit Ordner stehen oben als Zuordnung; hier nur die ohne.
        let mapped = Set(config.teamsByProjectPath.values.map { $0.uppercased() })
        staleTeams = config.workspacesByTeam
            .filter { !mapped.contains($0.key.uppercased()) && Self.isMissing(team: $0.key, in: byName[$0.value]) }
            .map { StaleTeam(team: $0.key, workspace: $0.value) }
            .sorted { $0.team < $1.team }
    }

    /// Der Schalter ist aus: Ein laufendes Laden fragt nicht weiter.
    func stop() {
        loadGeneration += 1
    }

    /// Prüft den Key bei Linear und legt ihn unter dem Workspace ab, den
    /// Linear zu ihm nennt. Ein abgelehnter Key wird nicht gespeichert, und der
    /// Key steht in keiner Meldung.
    @discardableResult
    func saveKey(_ raw: String) async -> Bool {
        // Return im Feld und der Knopf können beide auslösen.
        guard !isSavingKey else { return false }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TicketCredentialStore.isStorable(key) else {
            keyNotice = .failed(String(localized: "That does not look like a Linear API key."))
            return false
        }
        isSavingKey = true
        defer { isSavingKey = false }
        let deps = dependencies
        let account: TicketAccount
        switch await Self.offMain({ await deps.account(key) }) {
        case .failure(let error):
            keyNotice = .failed(error.userText)
            return false
        case .success(let found):
            account = found
        }
        let workspace = account.workspaceKey
        guard TicketConfig.isWorkspaceName(workspace) else {
            keyNotice = .failed(String(localized: "Linear did not name a workspace for this key."))
            return false
        }
        guard await TicketBlockingWork.run({ deps.storeKey(workspace, key) }) else {
            keyNotice = .failed(String(localized: "Couldn't save the key to the macOS Keychain. Unlock your Keychain and try again."))
            return false
        }
        guard await change({ $0.add(workspace: workspace) }) == .saved else {
            keyNotice = .failed(String(localized: "Couldn't save the ticket settings."))
            return false
        }
        keyNotice = .saved(String(localized: "Key saved for \(account.workspace), signed in as \(account.userName)."))
        await load()
        return true
    }

    /// Löscht den Key eines Workspaces aus dem Schlüsselbund. Der Workspace
    /// bleibt eingerichtet und steht danach als „ohne Key“ da, die Zuordnungen
    /// bleiben. Nähme die Seite ihn aus der Einrichtung, fiele ein Team ohne
    /// festen Workspace still dem einzigen verbliebenen zu.
    func removeKey(workspace: String) async {
        let deps = dependencies
        let removed = await TicketBlockingWork.run { deps.deleteKey(workspace) }
        keyNotice = removed ? nil
            : .failed(String(localized: "Couldn't remove the key from the macOS Keychain. Unlock your Keychain and try again."))
        await load()
    }

    /// Ordnet einen Projektordner einem Team zu. Ein Kürzel, das schon zu
    /// einem anderen Workspace gehört, wird nicht still umgehängt: Sonst
    /// schriebe jeder Ordner dieses Teams in den anderen Workspace.
    @discardableResult
    func assign(projectPath: String, to choice: TeamChoice) async -> Bool {
        // Prüfen und Schreiben in einem Zug: Der Stand der Datei im Augenblick des
        // Schreibens zählt, nicht der zuletzt angezeigte.
        let outcome = await change { config in
            if let current = config.workspacesByTeam[choice.team.uppercased()], current != choice.workspace {
                throw TeamTaken(workspace: current)
            }
            config.set(workspace: choice.workspace, forTeam: choice.team)
            config.set(team: choice.team, forProject: projectPath)
        }
        switch outcome {
        case .saved:
            mappingProblem = nil
            await load()
            return true
        case .refused(let current):
            mappingProblem = String(localized: "Team \(choice.team) is already linked to the workspace \(current). To move it, run: whisperm8 tickets setup --team \(choice.team) --workspace \(choice.workspace) --reassign")
            return false
        case .failed:
            mappingProblem = String(localized: "Couldn't save the ticket settings.")
            return false
        }
    }

    /// Löst einen Ordner von seinem Team. Hing er an einem Team, das sein
    /// Workspace nicht mehr kennt, geht mit dem letzten Ordner auch das Team
    /// aus der Einrichtung; sonst bliebe es als eigene Zeile stehen, und der
    /// Ordner ließe sich erst nach einem zweiten Klick neu zuordnen.
    func removeMapping(path: String) async {
        let goneTeam = mappings.first { $0.path == path && $0.teamMissing }?.team
        let outcome = await change { config in
            config.removeProject(path)
            if let goneTeam, config.projectPaths(forTeam: goneTeam).isEmpty { config.removeTeam(goneTeam) }
        }
        mappingProblem = outcome == .saved ? nil : String(localized: "Couldn't save the ticket settings.")
        await load()
    }

    /// Nimmt ein Team ohne Ordner aus der Einrichtung, das sein Workspace nicht
    /// mehr kennt. Hängt im Augenblick des Schreibens doch ein Ordner daran
    /// (die Kommandozeile schreibt dieselbe Datei), bleibt alles, wie es ist.
    func removeTeam(_ team: String) async {
        let outcome = await change { config in
            if config.projectPaths(forTeam: team).isEmpty { config.removeTeam(team) }
        }
        mappingProblem = outcome == .saved ? nil : String(localized: "Couldn't save the ticket settings.")
        await load()
    }

    private struct TeamTaken: Error {
        var workspace: String
    }

    private enum ChangeOutcome: Equatable {
        case saved
        /// Die Änderung selbst hat abgelehnt: Das Kürzel gehört schon zu diesem Workspace.
        case refused(String)
        case failed
    }

    /// Lesen, prüfen, ändern, schreiben in einem Zug, abseits des Main Threads
    /// und nacheinander. Die Kommandozeile schreibt dieselbe Datei; deshalb nie
    /// aus einem alten Stand, und nie auf einer Datei, die sich nicht lesen ließ.
    private func change(_ mutate: @escaping @Sendable (inout TicketConfig) throws -> Void) async -> ChangeOutcome {
        let deps = dependencies
        return await withCheckedContinuation { continuation in
            TicketConfigStore.changeQueue.async {
                do {
                    var config = try deps.loadConfigForChange()
                    try mutate(&config)
                    try deps.saveConfig(config)
                    continuation.resume(returning: .saved)
                } catch let taken as TeamTaken {
                    continuation.resume(returning: .refused(taken.workspace))
                } catch {
                    continuation.resume(returning: .failed)
                }
            }
        }
    }

    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        await Task.detached(priority: .userInitiated) { await work() }.value
    }
}
