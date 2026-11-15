import Foundation

/// Chats eines Projekts, die schon oben in einem Workspace stehen. Die
/// Projektgruppe zeigt sie nicht ein zweites Mal, sondern nur als eine
/// Hinweiszeile mit ihren Status-Punkten (WM8-80, Seitenleiste A).
struct SidebarWorkspaceHint: Equatable, Identifiable {
    var workspaceID: UUID
    var name: String
    /// In Slot-Reihenfolge des Workspaces.
    var sessionIDs: [UUID]

    var id: UUID { workspaceID }
}

/// Inhalt einer Projektgruppe nach Seitenleiste A: Hinweise auf Workspaces,
/// dann laufende Chats, dann gestoppte. Innerhalb beider Blöcke gilt die
/// Handreihenfolge (`AgentSessionStore.sortedSessions`).
struct SidebarProjectBlocks: Equatable {
    var workspaceHints: [SidebarWorkspaceHint] = []
    var running: [AgentChatSession] = []
    var stopped: [AgentChatSession] = []
    /// Läuft ein Chat des Projekts, auch einer, der nur im Workspace steht?
    var hasRunning = false

    /// Die Zeilen der Gruppe in Anzeige-Reihenfolge (ohne Workspace-Chats).
    var rows: [AgentChatSession] { running + stopped }
}

/// Pure Regeln von Seitenleiste A (WM8-80). „Läuft“ heißt: der Prozess lebt
/// (`runningSessionIDs` des Snapshots), nicht der Status-Punkt. Zeilen
/// springen deshalb nur bei Start und Stopp, und die Seitenleiste muss den
/// Activity-Store nicht beobachten.
enum AgentSidebarSorting {
    /// Teilt die schon in Handreihenfolge sortierten Chats eines Projekts in
    /// Workspace-Hinweise, laufende und gestoppte Chats. Ein Chat in mehreren
    /// Workspaces zählt zum ersten in gespeicherter Reihenfolge (dieselbe
    /// Regel wie die Tab-Herkunft, `AgentTabOrder.workspaceBySession`).
    static func blocks(
        sortedSessions: [AgentChatSession],
        runningSessionIDs: Set<UUID>,
        workspaceBySession: [UUID: UUID],
        workspaces: [AgentGridWorkspace]
    ) -> SidebarProjectBlocks {
        var result = SidebarProjectBlocks()
        var hintedIDs: [UUID: [UUID]] = [:]
        for session in sortedSessions {
            let isRunning = runningSessionIDs.contains(session.id)
            if isRunning { result.hasRunning = true }
            if let workspaceID = workspaceBySession[session.id] {
                hintedIDs[workspaceID, default: []].append(session.id)
            } else if isRunning {
                result.running.append(session)
            } else {
                result.stopped.append(session)
            }
        }
        guard !hintedIDs.isEmpty else { return result }
        for entity in workspaces {
            guard let ids = hintedIDs[entity.id] else { continue }
            let members = Set(ids)
            result.workspaceHints.append(SidebarWorkspaceHint(
                workspaceID: entity.id,
                name: entity.name,
                sessionIDs: entity.occupiedSessionIDs.filter { members.contains($0) }
            ))
        }
        return result
    }

    /// Projekte mit laufenden Chats zuerst, die übrigen danach unter
    /// „Ohne laufende Chats“. Die Handreihenfolge der Projekte bleibt in
    /// beiden Blöcken. `firstCalmIndex` ist die Stelle des Trenners, nur wenn
    /// es beide Blöcke gibt.
    static func orderedProjects(
        _ projects: [AgentProject],
        blocks: [UUID: SidebarProjectBlocks]
    ) -> (projects: [AgentProject], firstCalmIndex: Int?) {
        var live: [AgentProject] = []
        var calm: [AgentProject] = []
        for project in projects {
            if blocks[project.id]?.hasRunning == true {
                live.append(project)
            } else {
                calm.append(project)
            }
        }
        let firstCalmIndex = (live.isEmpty || calm.isEmpty) ? nil : live.count
        return (live + calm, firstCalmIndex)
    }

    /// Ist die Faltzeile „N gestoppt“ offen? Unter „Aktiv“ ist sie zu, unter
    /// „Zuletzt“ und „Alle“ offen; ein Klick überstimmt das je Projekt
    /// (`override`, gespeichert im UI-Zustand). Eine Suche öffnet sie immer,
    /// sonst wären Treffer unsichtbar.
    static func isStoppedFoldOpen(
        scope: SidebarScope,
        override: Bool?,
        isSearching: Bool
    ) -> Bool {
        if isSearching { return true }
        return override ?? (scope != .active)
    }

    /// Gestoppte Chats, die unter der Faltzeile stehen. Offen: bis zum
    /// Zeilen-Limit, der gewählte Chat (`revealID`) immer. Zu: nur der
    /// gewählte Chat, falls er gestoppt ist — so klappt beim Wechsel zwischen
    /// laufendem und gestopptem Chat nicht jedes Mal der ganze Block auf.
    static func visibleStopped(
        _ stopped: [AgentChatSession],
        foldOpen: Bool,
        limit: Int,
        revealID: UUID?
    ) -> (visible: [AgentChatSession], hiddenCount: Int) {
        guard foldOpen else {
            return (stopped.filter { $0.id == revealID }, 0)
        }
        var effectiveLimit = max(0, limit)
        if let revealID, let index = stopped.firstIndex(where: { $0.id == revealID }), index >= effectiveLimit {
            effectiveLimit = index + 1
        }
        let visible = Array(stopped.prefix(effectiveLimit))
        return (visible, stopped.count - visible.count)
    }
}
