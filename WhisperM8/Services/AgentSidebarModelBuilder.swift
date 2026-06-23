import Foundation

/// Welche Chats die Sidebar zeigt — orthogonal zum Layout. Default `.active`
/// hält die Liste klein (nur das Arbeitsset), ohne dass etwas verloren geht:
/// `.all` ist immer einen Klick entfernt, die Suche überstimmt den Scope.
/// `String`-RawValue, damit `@AppStorage` den Wert direkt persistiert.
enum SidebarScope: String, CaseIterable, Identifiable {
    /// Laufende Sessions ∪ offene Tabs (∪ gepinnt, in eigener Sektion).
    case active
    /// `.active` plus kürzlich aktive Chats (Recency-Fenster).
    case recent
    /// Alles — wie vor dem Filter, nach Projekt gruppierbar.
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .active: return "Aktiv"
        case .recent: return "Zuletzt"
        case .all: return "Alle"
        }
    }
}

/// Anordnung der Chat-Liste — orthogonal zum Scope. Gruppiert = projekt-
/// orientiert (heutiges Verhalten), flach = zeit-orientiert (Recency-Sort,
/// Repo-Badge pro Zeile). `String`-RawValue für `@AppStorage`.
enum SidebarLayout: String {
    case grouped
    case flat

    /// Icon des Toggle-Buttons: zeigt das ZIEL-Layout, nicht das aktuelle.
    var toggleIcon: String {
        switch self {
        case .grouped: return "list.bullet"          // → wechselt zu flach
        case .flat: return "rectangle.grid.1x2"      // → wechselt zu gruppiert
        }
    }
}

/// Auswertbarer Scope-Filter: kapselt die „Aktiv/Zuletzt/Alle"-Entscheidung
/// inkl. der Live-Eingaben (laufende Sessions, offene Tabs, Recency-Fenster),
/// damit der Builder testbar bleibt und die View nur Werte reicht.
struct SidebarScopeFilter {
    let scope: SidebarScope
    let runningSessionIDs: Set<UUID>
    let openTabIDs: Set<UUID>
    let now: Date
    let recentWindow: TimeInterval

    /// Standard-Recency-Fenster für „Zuletzt": 7 Tage.
    static let defaultRecentWindow: TimeInterval = 7 * 24 * 3600

    /// Filter, der nie etwas wegfiltert — Default für Aufrufer/Tests, die
    /// keinen Scope kennen (verhält sich exakt wie vor dem Feature).
    static let all = SidebarScopeFilter(
        scope: .all,
        runningSessionIDs: [],
        openTabIDs: [],
        now: Date(timeIntervalSince1970: 0),
        recentWindow: 0
    )

    /// Laufende Sessions sind in JEDEM Scope sichtbar — ein arbeitender Agent
    /// darf nie ausgeblendet werden.
    func matches(_ session: AgentChatSession) -> Bool {
        switch scope {
        case .all:
            return true
        case .active:
            return runningSessionIDs.contains(session.id)
                || openTabIDs.contains(session.id)
        case .recent:
            return runningSessionIDs.contains(session.id)
                || openTabIDs.contains(session.id)
                || session.lastActivityAt >= now.addingTimeInterval(-recentWindow)
        }
    }
}

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
        pinnedSessionIDs: Set<UUID>,
        scope: SidebarScopeFilter = .all
    ) -> [UUID: [AgentChatSession]] {
        var grouped: [UUID: [AgentChatSession]] = [:]
        for session in workspaceSessions {
            guard session.status != .archived,
                  session.isManuallyCreated,
                  !pinnedSessionIDs.contains(session.id),
                  scope.matches(session)
            else { continue }
            grouped[session.projectID, default: []].append(session)
        }
        return grouped.mapValues { AgentSessionStore.sortedSessions($0) }
    }

    /// Flache, projektübergreifende Chat-Liste für das `.flat`-Layout —
    /// Recency-sortiert (`lastActivityAt` absteigend), gepinnte/archivierte/
    /// nicht-manuelle Sessions raus, Scope angewandt. Jede Zeile trägt später
    /// ihr Repo-Badge, weil der Projekt-Header fehlt.
    static func flatSessions(
        workspaceSessions: [AgentChatSession],
        pinnedSessionIDs: Set<UUID>,
        scope: SidebarScopeFilter = .all
    ) -> [AgentChatSession] {
        workspaceSessions
            .filter {
                $0.status != .archived
                    && $0.isManuallyCreated
                    && !pinnedSessionIDs.contains($0.id)
                    && scope.matches($0)
            }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// Zähler für die drei Scopes (ohne gepinnte — die zeigt die Sidebar eh
    /// separat). Speist die „N von M sichtbar"-Anzeige, damit sich beim
    /// Filtern nichts versteckt anfühlt. Ein Durchlauf, O(n).
    static func scopeCounts(
        workspaceSessions: [AgentChatSession],
        pinnedSessionIDs: Set<UUID>,
        runningSessionIDs: Set<UUID>,
        openTabIDs: Set<UUID>,
        now: Date,
        recentWindow: TimeInterval = SidebarScopeFilter.defaultRecentWindow
    ) -> (active: Int, recent: Int, all: Int) {
        var active = 0
        var recent = 0
        var all = 0
        let recentThreshold = now.addingTimeInterval(-recentWindow)
        for session in workspaceSessions {
            guard session.status != .archived,
                  session.isManuallyCreated,
                  !pinnedSessionIDs.contains(session.id)
            else { continue }
            all += 1
            let isActive = runningSessionIDs.contains(session.id)
                || openTabIDs.contains(session.id)
            if isActive {
                active += 1
                recent += 1
            } else if session.lastActivityAt >= recentThreshold {
                recent += 1
            }
        }
        return (active, recent, all)
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
