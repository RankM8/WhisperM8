import Foundation

/// Pure Funktionen für das Sidebar-Modell (P4): Gruppierung + Suche in EINEM
/// Durchlauf statt pro Projekt neu zu filtern/sortieren. Die Semantik ist
/// 1:1 die der früheren `AgentChatsView.sessions(for:)`- und
/// `visibleProjects`-Logik — Tests in AgentSidebarTests.swift.
struct AgentSidebarModelBuilder {
    /// Sichtbarkeit: alle manuell erstellten, nicht-archivierten Sessions,
    /// die der User aktiv im Memory hat (openTabIDs) oder gerade selektiert.
    /// Sortierung pro Projekt wie `AgentSessionStore.sortedSessions`.
    static func sessionsByProject(
        workspaceSessions: [AgentChatSession],
        openTabIDs: Set<UUID>,
        selectedSessionID: UUID?
    ) -> [UUID: [AgentChatSession]] {
        var grouped: [UUID: [AgentChatSession]] = [:]
        for session in workspaceSessions {
            guard session.status != .archived,
                  session.isManuallyCreated,
                  openTabIDs.contains(session.id) || session.id == selectedSessionID
            else { continue }
            grouped[session.projectID, default: []].append(session)
        }
        return grouped.mapValues { AgentSessionStore.sortedSessions($0) }
    }

    /// Such-Semantik: Match auf Projektname, Pfad, Session-Titel,
    /// Provider-DisplayName und Gruppenname — case-insensitive. Leere Query
    /// liefert alle manuellen Projekte.
    static func visibleProjects(
        manualProjects: [AgentProject],
        sessionsByProject: [UUID: [AgentChatSession]],
        query: String
    ) -> [AgentProject] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return manualProjects }
        return manualProjects.filter { project in
            project.name.localizedCaseInsensitiveContains(trimmed)
                || project.path.localizedCaseInsensitiveContains(trimmed)
                || (sessionsByProject[project.id] ?? []).contains { session in
                    session.title.localizedCaseInsensitiveContains(trimmed)
                        || session.provider.displayName.localizedCaseInsensitiveContains(trimmed)
                        || (session.groupName?.localizedCaseInsensitiveContains(trimmed) == true)
                }
        }
    }
}
