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
        var id: String { path }
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
    private(set) var projects: [TicketProjectChoice]
    private(set) var isSavingKey = false
    private(set) var keyNotice: Notice?
    private(set) var mappingProblem: String?

    @ObservationIgnored private let dependencies: TicketsSettingsDependencies
    /// Zählt die Ladevorgänge. Nur der jüngste darf sein Ergebnis eintragen,
    /// und ein überholter fragt nicht weiter.
    @ObservationIgnored private var loadGeneration = 0

    init(dependencies: TicketsSettingsDependencies, workspaces: [Workspace] = [], mappings: [Mapping] = [],
         projects: [TicketProjectChoice] = []) {
        self.dependencies = dependencies
        self.workspaces = workspaces
        self.mappings = mappings
        self.projects = projects
    }

    /// Teams aller Workspaces mit Zugang, für die Auswahl beim Zuordnen.
    var teamChoices: [TeamChoice] {
        workspaces.flatMap { workspace in workspace.teams.map { TeamChoice(team: $0, workspace: workspace.name) } }
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
        let config = await Self.offMain { deps.loadConfig() }
        var loaded: [Workspace] = []
        for name in config.knownWorkspaces {
            guard isCurrent() else { return }
            var workspace = Workspace(name: name, hasKey: await Self.offMain { deps.hasKey(name) })
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
        mappings = config.teamsByProjectPath
            .map { Mapping(path: $0.key, team: $0.value, workspace: config.workspace(forTeam: $0.value)) }
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
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
        guard await Self.offMain({ deps.storeKey(workspace, key) }) else {
            keyNotice = .failed(String(localized: "Couldn't save the key to the macOS Keychain. Unlock your Keychain and try again."))
            return false
        }
        guard await change({ $0.add(workspace: workspace) }) else {
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
        let removed = await Self.offMain { deps.deleteKey(workspace) }
        keyNotice = removed ? nil
            : .failed(String(localized: "Couldn't remove the key from the macOS Keychain. Unlock your Keychain and try again."))
        await load()
    }

    /// Ordnet einen Projektordner einem Team zu. Ein Kürzel, das schon zu
    /// einem anderen Workspace gehört, wird nicht still umgehängt: Sonst
    /// schriebe jeder Ordner dieses Teams in den anderen Workspace.
    @discardableResult
    func assign(projectPath: String, to choice: TeamChoice) async -> Bool {
        let deps = dependencies
        // Der Stand der Datei zählt, nicht der zuletzt angezeigte.
        let current = await Self.offMain { deps.loadConfig().workspacesByTeam[choice.team.uppercased()] }
        if let current, current != choice.workspace {
            mappingProblem = String(localized: "Team \(choice.team) is already linked to the workspace \(current). To move it, run: whisperm8 tickets setup --team \(choice.team) --workspace \(choice.workspace) --reassign")
            return false
        }
        guard await change({
            $0.set(workspace: choice.workspace, forTeam: choice.team)
            $0.set(team: choice.team, forProject: projectPath)
        }) else {
            mappingProblem = String(localized: "Couldn't save the ticket settings.")
            return false
        }
        mappingProblem = nil
        await load()
        return true
    }

    func removeMapping(path: String) async {
        _ = await change { $0.removeProject(path) }
        mappingProblem = nil
        await load()
    }

    /// Lesen, ändern, schreiben in einem Zug, abseits des Main Threads und
    /// nacheinander. Die Kommandozeile schreibt dieselbe Datei; deshalb nie aus
    /// einem alten Stand, und nie auf einer Datei, die sich nicht lesen ließ.
    private func change(_ mutate: @escaping @Sendable (inout TicketConfig) -> Void) async -> Bool {
        let deps = dependencies
        return await withCheckedContinuation { continuation in
            TicketConfigStore.changeQueue.async {
                do {
                    var config = try deps.loadConfigForChange()
                    mutate(&config)
                    try deps.saveConfig(config)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        await Task.detached(priority: .userInitiated) { await work() }.value
    }
}
