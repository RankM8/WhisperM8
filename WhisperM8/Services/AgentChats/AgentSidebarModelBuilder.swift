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

/// Ergebnis von `subagentChildSplit` — die sichtbaren „aktiven" Kinder, der
/// verborgene fertige Rest (für den Fuß) und die Zähler, die der Parent-Chip
/// für den Fortschritts-Bruch braucht.
struct SubagentChildSplit: Equatable {
    /// Immer sichtbar unter der Parent-Row: fehlgeschlagen (Rang 0) + laufend
    /// (Rang 1), plus ein evtl. selektiertes Kind (Reveal).
    var visible: [AgentChatSession]
    /// Der Fuß-Inhalt: erfolgreich fertige Kinder, ungelesene zuerst.
    var hidden: [AgentChatSession]
    /// Wie viele der verborgenen Kinder ein ungelesenes Ergebnis tragen —
    /// speist den blauen Punkt am Fuß (nur „da ist was", keine Zahl).
    var hiddenUnreadCount: Int
    /// Fehlgeschlagene Kinder — roter Punkt am Chip.
    var erroredCount: Int
    /// Laufende Kinder — grüner Punkt am Chip.
    var workingCount: Int
    /// Gesamtzahl der Kinder — Nenner des Chip-Bruchs.
    var totalCount: Int
    /// Zähler des Chip-Bruchs: terminale (= nicht laufende) Kinder.
    var terminalCount: Int { totalCount - workingCount }
}

struct SidebarScopeCounts: Equatable {
    var active: Int
    var recent: Int
    var all: Int
}

struct AgentSidebarSnapshot {
    var projectByID: [UUID: AgentProject]
    var subagentChildrenByParent: [UUID: [AgentChatSession]]
    var sessionsByProject: [UUID: [AgentChatSession]]
    var visibleProjects: [AgentProject]
    var visibleFlatSessions: [AgentChatSession]
    var visibleFlatOrderIDs: [UUID]
    var flatHiddenCount: Int
    var visiblePinned: [AgentChatSession]
    var pinnedOrderIDs: [UUID]
    var scopeCounts: SidebarScopeCounts
    var chatCount: Int
    var chatListIsEmpty: Bool
    var hasManualProjects: Bool

    /// Fachlich sichtbare Root-Kandidaten. Das ist bewusst NICHT die Zahl der
    /// aktuell materialisierten SwiftUI-Rows: Collapse-State und das lokale
    /// 20er-Limit von `ProjectChatGroup` liegen erst in der View-Schicht.
    var eligibleRootRowCount: Int {
        visiblePinned.count + visibleFlatSessions.count
            + visibleProjects.reduce(0) {
                $0 + (sessionsByProject[$1.id]?.count ?? 0)
            }
    }
}

/// Pure Funktionen für das Sidebar-Modell (P4): Gruppierung + Suche in EINEM
/// Durchlauf statt pro Projekt neu zu filtern/sortieren.
/// Tests in AgentSidebarTests.swift.
struct AgentSidebarModelBuilder {
    static func snapshot(
        workspace: AgentWorkspace,
        pinnedSessionIDs: [UUID],
        scope: SidebarScopeFilter,
        layout: SidebarLayout,
        query: String,
        flatVisibleLimit: Int,
        selectedSessionID: UUID?
    ) -> AgentSidebarSnapshot {
        let manualProjects: [AgentProject]
        let hasManualProjects: Bool
        switch layout {
        case .grouped:
            manualProjects = AgentSessionStore.sortedProjects(
                workspace.projects.filter(\.isManuallyAdded)
            )
            hasManualProjects = !manualProjects.isEmpty
        case .flat:
            manualProjects = []
            hasManualProjects = workspace.projects.contains(where: \.isManuallyAdded)
        }
        let projectByID = Dictionary(
            workspace.projects.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let subagents = subagentChildren(workspaceSessions: workspace.sessions)
        var subagentChildIDs: Set<UUID> = []
        var parentIDByChildID: [UUID: UUID] = [:]
        for (parentID, children) in subagents.byParentLocalID {
            for child in children {
                subagentChildIDs.insert(child.id)
                parentIDByChildID[child.id] = parentID
            }
        }
        var effectiveRunningSessionIDs = scope.runningSessionIDs
        var effectiveOpenTabIDs = scope.openTabIDs
        for childID in scope.runningSessionIDs {
            if let parentID = parentIDByChildID[childID] {
                effectiveRunningSessionIDs.insert(parentID)
            }
        }
        for childID in scope.openTabIDs {
            if let parentID = parentIDByChildID[childID] {
                effectiveOpenTabIDs.insert(parentID)
            }
        }
        if let selectedSessionID,
           let parentID = parentIDByChildID[selectedSessionID] {
            effectiveOpenTabIDs.insert(parentID)
        }
        let effectiveScope = SidebarScopeFilter(
            scope: scope.scope,
            runningSessionIDs: effectiveRunningSessionIDs,
            openTabIDs: effectiveOpenTabIDs,
            now: scope.now,
            recentWindow: scope.recentWindow
        )
        let pinnedIDSet = Set(pinnedSessionIDs)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let recentThreshold = effectiveScope.now.addingTimeInterval(-effectiveScope.recentWindow)

        var activeCount = 0
        var recentCount = 0
        var allCount = 0
        var grouped: [UUID: [AgentChatSession]] = [:]
        var flat: [AgentChatSession] = []
        var sessionByID: [UUID: AgentChatSession] = [:]
        sessionByID.reserveCapacity(workspace.sessions.count)

        for session in workspace.sessions {
            if sessionByID[session.id] == nil {
                sessionByID[session.id] = session
            }
            guard session.status != .archived,
                  session.isManuallyCreated,
                  !pinnedIDSet.contains(session.id),
                  !subagentChildIDs.contains(session.id)
            else { continue }

            allCount += 1
            let isActive = effectiveScope.runningSessionIDs.contains(session.id)
                || effectiveScope.openTabIDs.contains(session.id)
            if isActive {
                activeCount += 1
                recentCount += 1
            } else if session.lastActivityAt >= recentThreshold {
                recentCount += 1
            }
            guard effectiveScope.matches(session) else { continue }

            switch layout {
            case .grouped:
                grouped[session.projectID, default: []].append(session)
            case .flat:
                guard matchesSearch(
                    session: session,
                    project: projectByID[session.projectID],
                    query: trimmedQuery
                ) else { continue }
                flat.append(session)
            }
        }

        let visiblePinned = pinnedSessionIDs
            .compactMap { sessionByID[$0] }
            .filter {
                $0.status != .archived
                    && (trimmedQuery.isEmpty
                        || $0.title.localizedCaseInsensitiveContains(trimmedQuery))
            }
        let pinnedOrderIDs = visiblePinned.map(\.id)

        var sessionsByProject: [UUID: [AgentChatSession]] = [:]
        var visibleProjects: [AgentProject] = []
        var visibleFlatSessions: [AgentChatSession] = []
        var visibleFlatOrderIDs: [UUID] = []
        var flatHiddenCount = 0
        let chatCount: Int
        let chatListIsEmpty: Bool

        switch layout {
        case .grouped:
            sessionsByProject = grouped.mapValues { AgentSessionStore.sortedSessions($0) }
            visibleProjects = Self.visibleProjects(
                manualProjects: manualProjects,
                sessionsByProject: sessionsByProject,
                query: trimmedQuery
            ).filter {
                scope.scope == .all || !(sessionsByProject[$0.id] ?? []).isEmpty
            }
            chatCount = visibleProjects.reduce(0) {
                $0 + (sessionsByProject[$1.id]?.count ?? 0)
            }
            chatListIsEmpty = visibleProjects.isEmpty
        case .flat:
            flat.sort { $0.lastActivityAt > $1.lastActivityAt }
            var revealID = selectedSessionID
            if let selectedSessionID,
               !flat.contains(where: { $0.id == selectedSessionID }) {
                revealID = parentIDByChildID[selectedSessionID]
            }
            let slice = visibleSlice(
                of: flat,
                limit: flatVisibleLimit,
                mustIncludeID: revealID
            )
            visibleFlatSessions = slice.visible
            visibleFlatOrderIDs = slice.visible.map(\.id)
            flatHiddenCount = slice.hiddenCount
            chatCount = flat.count
            chatListIsEmpty = flat.isEmpty
        }

        return AgentSidebarSnapshot(
            projectByID: projectByID,
            subagentChildrenByParent: subagents.byParentLocalID,
            sessionsByProject: sessionsByProject,
            visibleProjects: visibleProjects,
            visibleFlatSessions: visibleFlatSessions,
            visibleFlatOrderIDs: visibleFlatOrderIDs,
            flatHiddenCount: flatHiddenCount,
            visiblePinned: visiblePinned,
            pinnedOrderIDs: pinnedOrderIDs,
            scopeCounts: SidebarScopeCounts(
                active: activeCount,
                recent: recentCount,
                all: allCount
            ),
            chatCount: chatCount,
            chatListIsEmpty: chatListIsEmpty,
            hasManualProjects: hasManualProjects
        )
    }

    private static func visibleSlice(
        of sessions: [AgentChatSession],
        limit: Int,
        mustIncludeID: UUID?
    ) -> (visible: [AgentChatSession], hiddenCount: Int) {
        let cappedLimit = max(0, limit)
        var visible = Array(sessions.prefix(cappedLimit))
        if let mustIncludeID,
           !visible.contains(where: { $0.id == mustIncludeID }),
           let selected = sessions.first(where: { $0.id == mustIncludeID }) {
            if visible.isEmpty {
                visible.append(selected)
            } else {
                // Reveal ersetzt die letzte Prefix-Row, statt das harte Limit
                // zu überschreiten. Beim nächsten +50-Schritt erscheinen so
                // tatsächlich 50 neue eindeutige Rows.
                visible[visible.count - 1] = selected
            }
        }
        return (visible, sessions.count - visible.count)
    }

    private static func matchesSearch(
        session: AgentChatSession,
        project: AgentProject?,
        query: String
    ) -> Bool {
        guard !query.isEmpty else { return true }
        return project?.name.localizedCaseInsensitiveContains(query) == true
            || project?.path.localizedCaseInsensitiveContains(query) == true
            || session.title.localizedCaseInsensitiveContains(query)
            || session.provider.displayName.localizedCaseInsensitiveContains(query)
            || session.groupName?.localizedCaseInsensitiveContains(query) == true
    }

    /// Sichtbarkeit (Redesign Juni 2026): die Sidebar ist die CHAT-LISTE —
    /// alle manuell erstellten, nicht-archivierten Sessions, unabhängig
    /// davon, ob gerade ein Tab dafür offen ist (Tabs sind die „aktive
    /// Auswahl" oben, die Sidebar der Bestand). Gepinnte Sessions wandern
    /// exklusiv in die Gepinnt-Sektion und fallen hier raus.
    /// Sortierung pro Projekt wie `AgentSessionStore.sortedSessions`.
    /// Subagent-Kinder mit auflösbarem Parent werden aus der Hauptliste
    /// herausgehalten (`subagentChildIDs`) — sie rendern eingerückt unter
    /// ihrer Parent-Row. Orphans (Parent weg/archiviert) bleiben drin und
    /// fallen als normale Rows ins Projekt zurück.
    static func sessionsByProject(
        workspaceSessions: [AgentChatSession],
        pinnedSessionIDs: Set<UUID>,
        scope: SidebarScopeFilter = .all,
        subagentChildIDs: Set<UUID> = []
    ) -> [UUID: [AgentChatSession]] {
        var grouped: [UUID: [AgentChatSession]] = [:]
        for session in workspaceSessions {
            guard session.status != .archived,
                  session.isManuallyCreated,
                  !pinnedSessionIDs.contains(session.id),
                  !subagentChildIDs.contains(session.id),
                  scope.matches(session)
            else { continue }
            grouped[session.projectID, default: []].append(session)
        }
        return grouped.mapValues { AgentSessionStore.sortedSessions($0) }
    }

    /// Gruppiert `.subagentJob`-Sessions unter ihre Parent-Session (Match:
    /// `subagentParentSessionID` == Claude-`externalSessionID` des Parents).
    /// Kinder ohne auffindbaren, sichtbaren Parent (Parent archiviert, nie
    /// importiert, `--parent` fehlte) landen in `orphans` und werden von den
    /// Hauptlisten als normale Rows gerendert. Pure + testbar.
    static func subagentChildren(
        workspaceSessions: [AgentChatSession]
    ) -> (byParentLocalID: [UUID: [AgentChatSession]], orphans: [AgentChatSession]) {
        // Nur Parents, deren Row überhaupt rendert (manuell + nicht
        // archiviert) — sonst hinge das Kind unerreichbar unter einer
        // unsichtbaren Zeile.
        var parentIDByExternalID: [String: UUID] = [:]
        for session in workspaceSessions {
            guard !session.isSubagentJob,
                  session.isManuallyCreated,
                  session.status != .archived,
                  let externalID = session.externalSessionID, !externalID.isEmpty
            else { continue }
            parentIDByExternalID[externalID] = session.id
        }

        var byParent: [UUID: [AgentChatSession]] = [:]
        var orphans: [AgentChatSession] = []
        for session in workspaceSessions {
            guard session.isSubagentJob, session.status != .archived else { continue }
            if let parentExtID = session.subagentParentSessionID,
               let parentID = parentIDByExternalID[parentExtID] {
                byParent[parentID, default: []].append(session)
            } else {
                orphans.append(session)
            }
        }
        return (byParent.mapValues { AgentSessionStore.sortedSessions($0) }, orphans)
    }

    /// Variante D (beschlossen 2026-07-09): Von den Subagent-Kindern eines
    /// Parents bleiben nur die „aktiven" sichtbar — fehlgeschlagene
    /// (`errored`, Rang 0) und laufende (`working`, Rang 1). Alles erfolgreich
    /// Fertige fällt in den FUSS (`hidden`), ungelesene zuerst. Ein selektiertes
    /// Kind bleibt sichtbar, auch wenn es gerade fertig wurde (Reveal — sonst
    /// spränge die Auswahl in den eingeklappten Fuß).
    ///
    /// Der Aufrufer liefert reine ID-Mengen — kein Store, kein `AgentJobState`
    /// —, damit die Funktion pur + testbar bleibt:
    ///   • `erroredIDs` = Jobs mit `state == .failed`
    ///   • `workingIDs` = aktive Jobs (spawning/running) ∪ übernommene mit
    ///     lebender PTY
    ///   • `unreadIDs`  = fertige Jobs mit noch ungelesenem Ergebnis
    /// Was in keiner Menge steht, gilt als „fertig, gesichtet".
    ///
    /// Der Chip-Bruch am Parent ist `terminalCount / totalCount` mit
    /// `terminalCount = total − working` (beschlossen: terminal zählt, ein
    /// Fehlschlag ist Fortschritt — das Scheitern trägt der rote Punkt).
    /// Tests in AgentSidebarTests.swift.
    static func subagentChildSplit(
        children: [AgentChatSession],
        erroredIDs: Set<UUID>,
        workingIDs: Set<UUID>,
        unreadIDs: Set<UUID>,
        selectedID: UUID?
    ) -> SubagentChildSplit {
        var errored: [AgentChatSession] = []
        var working: [AgentChatSession] = []
        var revealed: [AgentChatSession] = []
        var hiddenUnread: [AgentChatSession] = []
        var hiddenSeen: [AgentChatSession] = []

        for child in children {
            if erroredIDs.contains(child.id) {
                errored.append(child)
            } else if workingIDs.contains(child.id) {
                working.append(child)
            } else if child.id == selectedID {
                revealed.append(child)          // fertig, aber selektiert → sichtbar
            } else if unreadIDs.contains(child.id) {
                hiddenUnread.append(child)
            } else {
                hiddenSeen.append(child)
            }
        }

        // Sichtbar: errored (Rang 0) vor working (Rang 1) vor Reveal, je Recency.
        let visible = sortByRecency(errored)
            + sortByRecency(working)
            + sortByRecency(revealed)
        // Fuß: ungelesene zuerst, dann gesichtete — je Recency.
        let hidden = sortByRecency(hiddenUnread) + sortByRecency(hiddenSeen)

        return SubagentChildSplit(
            visible: visible,
            hidden: hidden,
            hiddenUnreadCount: hiddenUnread.count,
            erroredCount: errored.count,
            workingCount: working.count,
            totalCount: children.count
        )
    }

    /// Stabiler Recency-Sort (neueste zuerst), Tiebreak über die ID-UUID —
    /// sonst flackert die Reihenfolge, wenn ein Workflow mehrere Kinder in
    /// derselben Sekunde spawnt.
    private static func sortByRecency(_ sessions: [AgentChatSession]) -> [AgentChatSession] {
        sessions.sorted {
            if $0.lastActivityAt != $1.lastActivityAt {
                return $0.lastActivityAt > $1.lastActivityAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Flache, projektübergreifende Chat-Liste für das `.flat`-Layout —
    /// Recency-sortiert (`lastActivityAt` absteigend), gepinnte/archivierte/
    /// nicht-manuelle Sessions raus, Scope angewandt. Jede Zeile trägt später
    /// ihr Repo-Badge, weil der Projekt-Header fehlt.
    static func flatSessions(
        workspaceSessions: [AgentChatSession],
        pinnedSessionIDs: Set<UUID>,
        scope: SidebarScopeFilter = .all,
        subagentChildIDs: Set<UUID> = []
    ) -> [AgentChatSession] {
        workspaceSessions
            .filter {
                $0.status != .archived
                    && $0.isManuallyCreated
                    && !pinnedSessionIDs.contains($0.id)
                    && !subagentChildIDs.contains($0.id)
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
        recentWindow: TimeInterval = SidebarScopeFilter.defaultRecentWindow,
        subagentChildIDs: Set<UUID> = []
    ) -> (active: Int, recent: Int, all: Int) {
        var active = 0
        var recent = 0
        var all = 0
        let recentThreshold = now.addingTimeInterval(-recentWindow)
        for session in workspaceSessions {
            guard session.status != .archived,
                  session.isManuallyCreated,
                  !pinnedSessionIDs.contains(session.id),
                  !subagentChildIDs.contains(session.id)
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
