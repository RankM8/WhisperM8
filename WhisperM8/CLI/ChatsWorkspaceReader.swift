import Foundation

// MARK: - Read-only-Workspace-Sicht für `whisperm8 chats`

/// Eine Session mit ihrem Projekt-Join — die Arbeitseinheit aller
/// `chats`-Lesebefehle.
struct ChatsSessionEntry: Equatable {
    var session: AgentChatSession
    var projectName: String
    var projectPath: String
}

/// Read-only-Sicht auf Workspace + UI-State für den CLI-Prozess.
///
/// WICHTIG: bewusst NICHT über `AgentSessionStore`/`AgentWorkspaceStoreRegistry`
/// — die halten prozessweite In-Memory-Kopien und persistieren als
/// Nebenwirkung (`loadUIState()` migriert und SCHREIBT). Der CLI-Prozess liest
/// ausschließlich von Disk: `AgentWorkspaceRepository.load` (reine Disk-Funktion
/// mit Backup-Recovery) + direkter `JSONDecoder` auf `agent-ui-state.json`.
///
/// Caveat (dokumentiert in docs/plans/whisperm8-chats-cli/): die laufende App
/// schreibt debounced (0,5 s) — der Disk-Stand kann Sekunden hinterherhinken.
/// Für Lese-Befehle akzeptiert; Mutationen laufen ohnehin über den Socket.
struct ChatsWorkspaceReader {
    var workspaceFileURL: URL?
    var uiStateFileURL: URL

    init(workspaceFileURL: URL? = nil, uiStateFileURL: URL? = nil) {
        self.workspaceFileURL = workspaceFileURL
        self.uiStateFileURL = uiStateFileURL ?? Self.defaultUIStateFileURL()
    }

    struct View {
        var workspace: AgentWorkspace
        var uiState: AgentUIState?
        var entries: [ChatsSessionEntry]
        var projects: [AgentProject]
        /// Sessions, die aktuell in irgendeinem Fenster als Tab offen sind
        /// (Vereinigung aller Fenster-Tab-Listen + globaler Kompat-Liste) —
        /// die Datenbasis für die App-„Aktiv"-Ansicht und `isOpen`.
        var openTabIDs: Set<UUID>
        /// In der Sidebar angepinnte Sessions.
        var pinnedSessionIDs: Set<UUID>
    }

    func load() -> View {
        // loadReadOnly: garantiert ohne Schreib-Nebenwirkung — load(migrate:)
        // würde bei Decode-Fehlern Quarantäne-Backups schreiben (GPT-Review).
        let workspace = AgentWorkspaceRepository(fileURL: workspaceFileURL).loadReadOnly()
        let uiState = loadUIStateReadOnly()
        let projectsByID = Dictionary(uniqueKeysWithValues: workspace.projects.map { ($0.id, $0) })
        let entries = workspace.sessions.compactMap { session -> ChatsSessionEntry? in
            guard let project = projectsByID[session.projectID] else { return nil }
            return ChatsSessionEntry(session: session, projectName: project.name, projectPath: project.path)
        }
        var openTabs = Set(uiState?.openTabIDs ?? [])
        for window in uiState?.windows ?? [] {
            openTabs.formUnion(window.openTabIDs)
        }
        let pinned = Set(uiState?.pinnedSessionIDs ?? [])
        return View(workspace: workspace, uiState: uiState, entries: entries,
                    projects: workspace.projects, openTabIDs: openTabs, pinnedSessionIDs: pinned)
    }

    /// Direkter Decode ohne Migration und ohne Schreib-Nebenwirkung.
    /// Decode-Fehler → `nil` (UI-State ist für die CLI nur Zusatzinfo).
    private func loadUIStateReadOnly() -> AgentUIState? {
        guard let data = try? Data(contentsOf: uiStateFileURL) else { return nil }
        return try? JSONDecoder().decode(AgentUIState.self, from: data)
    }

    static func defaultUIStateFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("agent-ui-state.json")
    }
}

// MARK: - Aufrufer-Identität

/// Identität der aufrufenden Session aus der PTY-Umgebung. Die App injiziert
/// beide Variablen beim Spawn (`AgentTerminalController.start()`); außerhalb
/// einer WhisperM8-PTY sind sie leer → Aufrufer ist „extern".
struct ChatsCallerIdentity: Equatable {
    var sessionID: UUID?
    var token: String?

    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> ChatsCallerIdentity {
        ChatsCallerIdentity(
            sessionID: env["WHISPERM8_SESSION_ID"].flatMap(UUID.init(uuidString:)),
            token: env["WHISPERM8_SESSION_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}
