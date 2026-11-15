import SwiftUI

/// Was eine Projektgruppe der Seitenleiste von den fensterweiten Mengen
/// wirklich sieht (WM8-101).
///
/// **Warum:** Jede Gruppe bekam bisher die globale Auswahl, alle offenen Tabs,
/// alle Mehrfach-Auswahlen und so weiter, dazu frische Closures. Damit galt
/// jede der 248 Gruppen bei jedem Auswahlwechsel als geändert und wurde neu
/// ausgewertet, auch die, in denen sich nichts ändert. Gemessen im Test mit
/// 248 Projekten: 240 ms je Wechsel (Debug-Build). Der Container bleibt
/// trotzdem ein `VStack` — `LazyVStack` mit `.draggable` hat im Mai 2026 die
/// App eingefroren (60ca683).
///
/// Hier werden die Mengen auf die Chats der Gruppe zugeschnitten. Was die
/// Gruppe nicht anzeigt, kommt nicht an; eine unbeteiligte Gruppe hat danach
/// dieselben Eingaben wie vorher und wird per `.equatable()` übersprungen.
struct SidebarProjectGroupInputs: Equatable {
    var selectedSessionID: UUID?
    var multiSelection: Set<UUID>
    var openTabIDs: Set<UUID>
    var autoRenamingSessionIDs: Set<UUID>
    var missingTranscriptSessionIDs: Set<UUID>
    var subagentChildrenByParent: [UUID: [AgentChatSession]]
    var workingSubagentSessionIDs: Set<UUID>
    var erroredSubagentSessionIDs: Set<UUID>
    var unreadSubagentSessionIDs: Set<UUID>
    var expandedSubagentParentIDs: Set<UUID>

    /// Alle Chats, die die Gruppe zeigt oder auf die sie verweist: eigene
    /// Zeilen, Chats in ihren Workspace-Hinweisen und Subagent-Kinder ihrer
    /// Zeilen. Auf diese Menge schneidet `narrowed` zu.
    static func sessionIDs(
        blocks: SidebarProjectBlocks,
        subagentChildrenByParent: [UUID: [AgentChatSession]]
    ) -> Set<UUID> {
        var ids = Set<UUID>()
        for row in blocks.rows {
            ids.insert(row.id)
            for child in subagentChildrenByParent[row.id] ?? [] { ids.insert(child.id) }
        }
        for hint in blocks.workspaceHints { ids.formUnion(hint.sessionIDs) }
        return ids
    }

    static func narrowed(
        blocks: SidebarProjectBlocks,
        selectedSessionID: UUID?,
        multiSelection: Set<UUID>,
        openTabIDs: Set<UUID>,
        autoRenamingSessionIDs: Set<UUID>,
        missingTranscriptSessionIDs: Set<UUID>,
        subagentChildrenByParent: [UUID: [AgentChatSession]],
        workingSubagentSessionIDs: Set<UUID>,
        erroredSubagentSessionIDs: Set<UUID>,
        unreadSubagentSessionIDs: Set<UUID>,
        expandedSubagentParentIDs: Set<UUID>
    ) -> SidebarProjectGroupInputs {
        let ids = sessionIDs(blocks: blocks, subagentChildrenByParent: subagentChildrenByParent)
        var children: [UUID: [AgentChatSession]] = [:]
        for row in blocks.rows {
            if let list = subagentChildrenByParent[row.id] { children[row.id] = list }
        }
        return SidebarProjectGroupInputs(
            selectedSessionID: selectedSessionID.flatMap { ids.contains($0) ? $0 : nil },
            multiSelection: multiSelection.intersection(ids),
            openTabIDs: openTabIDs.intersection(ids),
            autoRenamingSessionIDs: autoRenamingSessionIDs.intersection(ids),
            missingTranscriptSessionIDs: missingTranscriptSessionIDs.intersection(ids),
            subagentChildrenByParent: children,
            workingSubagentSessionIDs: workingSubagentSessionIDs.intersection(ids),
            erroredSubagentSessionIDs: erroredSubagentSessionIDs.intersection(ids),
            unreadSubagentSessionIDs: unreadSubagentSessionIDs.intersection(ids),
            expandedSubagentParentIDs: expandedSubagentParentIDs.intersection(ids)
        )
    }
}

/// Alles, wovon das Aussehen einer Projektgruppe abhängt, auch die Werte, die
/// ihre Closures beim Aufbau einfangen. Gleicher Schlüssel heißt: die alte
/// Gruppe samt ihren Closures ist noch richtig.
struct SidebarProjectGroupKey: Equatable {
    var project: AgentProject
    var blocks: SidebarProjectBlocks
    var inputs: SidebarProjectGroupInputs
    var isExpanded: Bool
    var worktreeProjects: [AgentProject]
    var activeSessionIDs: Set<UUID>
    var isWorkspaceOpen: Bool
    var workspaceOccupancyLabel: String?
    var sidebarScope: SidebarScope
    var isSearching: Bool
    var stoppedFoldOverride: Bool?
    /// Was das Kontextmenü der Zeilen aus fensterweitem Zustand liest. Das
    /// Menü wird beim Auswerten der Gruppe gebaut; ohne diese Werte zeigte
    /// eine übersprungene Gruppe ein Menü vom Stand ihres letzten Neuaufbaus.
    var menu: SidebarGroupMenuState
}

/// Fensterweite Werte, die `sessionContextMenu` für die Zeilen einer Gruppe
/// liest (WM8-101, Auflage aus dem Gegenlesen). Was nur die Chats der Gruppe
/// betrifft, ist auf sie zugeschnitten; was jede Zeile gleich betrifft
/// (Workspaces, Konten), steht ganz drin. Alles hier ändert sich selten.
struct SidebarGroupMenuState: Equatable {
    struct WorkspaceEntry: Equatable {
        var id: UUID
        var name: String
        var slots: [UUID?]
    }

    /// Ganze Mehrfachauswahl: Zahl und Mitglieder bestimmen „N Tabs
    /// schließen“, „N anpinnen“, „N Chats archivieren“, „Zu Account …“.
    var multiSelection: Set<UUID>
    /// Pin-Zustand der Auswahl („N anpinnen“ oder „N lösen“).
    var pinnedInSelection: Set<UUID>
    /// „Zu Workspace hinzufügen“: kuratierte Workspaces mit Belegung (Haken).
    var workspaces: [WorkspaceEntry]
    /// „In Platz setzen“ im sichtbaren Raster, `nil` ohne Raster.
    var visibleGrid: WorkspaceEntry?
    var claudeProfiles: [ClaudeAccountProfile]
    var gptProfiles: [GPTAccountProfile]
    var accountBulkMoveEnabled: Bool
    /// Vorgemerkter Kontowechsel der Chats dieser Gruppe (Ziel-Name).
    var pendingAccountSwitches: [UUID: String]
    var hasUndoableAccountMove: Bool
    /// Hintergrund-Chats der Gruppe mit laufender Aktion (Einträge gesperrt).
    var pendingLifecycle: Set<UUID>
    /// Job-Zustand der Gruppe: übernommen bzw. stoppbar (Laufzeit-Einträge).
    var takenOverJobs: Set<UUID>
    var stoppableJobs: Set<UUID>

    static func make(
        groupSessionIDs ids: Set<UUID>,
        multiSelection: Set<UUID>,
        pinnedSessionIDs: [UUID],
        gridWorkspaces: [AgentGridWorkspace],
        visibleGrid: AgentGridWorkspace?,
        claudeProfiles: [ClaudeAccountProfile],
        gptProfiles: [GPTAccountProfile],
        accountBulkMoveEnabled: Bool,
        pendingAccountSwitches: [UUID: String],
        hasUndoableAccountMove: Bool,
        pendingLifecycle: Set<UUID>,
        takenOverJobs: Set<UUID>,
        stoppableJobs: Set<UUID>
    ) -> SidebarGroupMenuState {
        func entry(_ workspace: AgentGridWorkspace) -> WorkspaceEntry {
            WorkspaceEntry(id: workspace.id, name: workspace.name, slots: workspace.slots)
        }
        return SidebarGroupMenuState(
            multiSelection: multiSelection,
            pinnedInSelection: multiSelection.isEmpty ? [] : Set(pinnedSessionIDs).intersection(multiSelection),
            workspaces: gridWorkspaces.filter { $0.sourceProjectID == nil }.map(entry),
            visibleGrid: visibleGrid.map(entry),
            claudeProfiles: claudeProfiles,
            gptProfiles: gptProfiles,
            accountBulkMoveEnabled: accountBulkMoveEnabled,
            pendingAccountSwitches: pendingAccountSwitches.filter { ids.contains($0.key) },
            hasUndoableAccountMove: hasUndoableAccountMove,
            pendingLifecycle: pendingLifecycle.intersection(ids),
            takenOverJobs: takenOverJobs.intersection(ids),
            stoppableJobs: stoppableJobs.intersection(ids)
        )
    }
}

/// Überspringt die Auswertung seines Inhalts, solange der Schlüssel gleich
/// bleibt. Nur mit `.equatable()` verwenden.
struct SidebarSkippingGroup<Content: View>: View, Equatable {
    let key: SidebarProjectGroupKey
    @ViewBuilder let content: () -> Content

    var body: some View { content() }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
}
