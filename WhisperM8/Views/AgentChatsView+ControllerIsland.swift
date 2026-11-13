import SwiftUI

// Dynamic Island am Controller (Insel-Paket): Projekte im Reiter
// „Workspaces & Projekte“, Archiv aus dem Options-Menü und das Konto des
// Chats für Kopf und Limits-Karte. Alles nur im Ereignis-Pfad, nie im Body.

extension AgentChatsView {
    /// Angelegte Workspaces, darunter die Projekte mit aktiven Chats, in der
    /// Reihenfolge der Seitenleiste (L2 „Wohin“). Ein Projekt steht auch ohne
    /// aktive Chats da, wenn sein Raster gerade sichtbar ist.
    func controllerWorkspaceChoices() -> [ControllerWorkspaceChoice] {
        let statusStore = runtimeStatusStore
        let status: (UUID) -> AgentSessionRuntimeStatus? = { statusStore.status(for: $0) }
        let workspaces = ControllerWorkspaceChoice.choices(
            from: windowStore.gridWorkspaces,
            currentID: isGridActive ? windowStore.window(for: windowID).activeWorkspaceID : nil,
            status: status
        )
        return workspaces + controllerProjectChoices(status: status)
    }

    private func controllerProjectChoices(
        status: (UUID) -> AgentSessionRuntimeStatus?
    ) -> [ControllerWorkspaceChoice] {
        let active = controllerActiveSessionIDsByProject()
        let shownProjectID = isGridActive ? activeGridWorkspaceEntity?.sourceProjectID : nil
        let views = Dictionary(
            windowStore.gridWorkspaces.compactMap { entity in entity.sourceProjectID.map { ($0, entity.id) } },
            uniquingKeysWith: { first, _ in first })
        return ControllerWorkspaceChoice.projectChoices(
            from: manualProjects.map { ($0.id, $0.name, $0.color) },
            active: active, shownProjectID: shownProjectID, views: views, status: status)
    }

    /// Aktive Chats je Projekt — dieselbe Ableitung wie der ⊞ am Projektkopf
    /// (laufend oder als Tab offen, über alle Fenster).
    private func controllerActiveSessionIDsByProject() -> [UUID: Set<UUID>] {
        AgentSidebarModelBuilder.activeSessionIDsByProject(
            sessions: workspace.sessions,
            runningSessionIDs: Self.runningSessionIDs(
                terminalActive: terminalRegistry.activeSessionIDs, jobRuntime: jobRuntimeModel),
            globalOpenTabIDs: windowStore.allWindowOpenTabIDs
        )
    }

    /// Projekt als Raster öffnen wie der ⊞ am Projektkopf, aber still: Bei
    /// einem Konflikt kommt nichts nach vorn und keine Meldung.
    func switchToProjectFromController(_ projectID: UUID) -> Bool {
        guard let project = workspace.projects.first(where: { $0.id == projectID }) else { return false }
        let active = controllerActiveSessionIDsByProject()[projectID] ?? []
        return openProjectAsWorkspace(project, activeSessionIDs: active, reportConflicts: false)
    }

    /// Wie der Archiv-Knopf unten in der Seitenleiste.
    func toggleArchiveModeFromController() {
        if archiveModeActive {
            exitArchiveMode()
        } else {
            archiveModeActive = true
        }
    }

    /// Konto, dessen Limits der Chat belastet: GPT-Chats (über das GPT-Backend)
    /// ihr GPT-Konto, Claude-Chats ihr Claude-Konto. Codex und Shells keins.
    func controllerUsageAccount(of session: AgentChatSession) -> ControllerUsageAccount? {
        guard session.provider == .claude, !session.isTerminal else { return nil }
        if session.claudeBackendModel != nil {
            return ControllerUsageAccount(kind: .gpt, name: session.gptProfileName ?? GPTAccountProfiles.mainProfileName)
        }
        return ControllerUsageAccount(kind: .claude, name: session.claudeProfileName ?? ClaudeAccountProfiles.mainProfileName)
    }
}
