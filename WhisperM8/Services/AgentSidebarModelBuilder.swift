import Foundation

/// Pure Funktionen für das Sidebar-Modell (P4): Gruppierung + Suche in EINEM
/// Durchlauf statt pro Projekt neu zu filtern/sortieren.
/// Tests in AgentSidebarTests.swift.
struct AgentSidebarModelBuilder {
    /// Sichtbarkeit (Redesign Juni 2026): die Sidebar ist die CHAT-LISTE —
    /// alle manuell erstellten, nicht-archivierten Sessions, unabhängig
    /// davon, ob gerade ein Tab dafür offen ist (Tabs sind die „aktive
    /// Auswahl" oben, die Sidebar der Bestand). Gepinnte Sessions wandern
    /// exklusiv in die Gepinnt-Sektion und fallen hier raus.
    /// Sortierung pro Projekt wie `AgentSessionStore.sortedSessions`.
    static func sessionsByProject(
        workspaceSessions: [AgentChatSession],
        pinnedSessionIDs: Set<UUID>
    ) -> [UUID: [AgentChatSession]] {
        var grouped: [UUID: [AgentChatSession]] = [:]
        for session in workspaceSessions {
            guard session.status != .archived,
                  session.isManuallyCreated,
                  !pinnedSessionIDs.contains(session.id)
            else { continue }
            grouped[session.projectID, default: []].append(session)
        }
        return grouped.mapValues { AgentSessionStore.sortedSessions($0) }
    }

    /// Gepinnte Sessions in Pin-Reihenfolge. Archivierte und unbekannte
    /// IDs fallen raus (die Persistenz räumt sie beim nächsten Load weg).
    static func pinnedSessions(
        workspaceSessions: [AgentChatSession],
        pinnedSessionIDs: [UUID]
    ) -> [AgentChatSession] {
        let byID = Dictionary(workspaceSessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return pinnedSessionIDs
            .compactMap { byID[$0] }
            .filter { $0.status != .archived }
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
