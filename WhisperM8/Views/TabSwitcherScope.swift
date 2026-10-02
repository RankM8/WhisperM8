import Foundation

/// Umfang und Reihenfolge des Ctrl+Tab-Switchers (docs/plans/tab-switcher-workspace.md,
/// Slice S1). Pur, window-frei → unit-testbar.
///
/// Drei Situationen, sonst kein Switcher — einen globalen Modus über alle
/// offenen Tabs gibt es nicht mehr (Übersicht ist Sache der Sidebar):
///
/// - **A** `.grid` — Grid sichtbar: belegte Slots des aktiven Workspace.
/// - **B** `.workspaceMap` — Einzelansicht, der selektierte Chat liegt im
///   Workspace, den das Fenster referenziert (maximiert): dessen Slots.
/// - **C** `.project` — Einzelansicht ohne Workspace-Bezug: offene Tabs
///   desselben Projekts in Tab-Leisten-Reihenfolge.
///
/// Reihenfolge im Workspace = Slot-Index aufsteigend — die Slots SIND die
/// Leserichtung (links → rechts, oben → unten), jeder Chat kommt immer an
/// derselben Stelle dran.
enum TabSwitcherScope: Equatable {
    case grid(order: [UUID])
    case workspaceMap(workspaceID: UUID, order: [UUID])
    case project(order: [UUID])

    /// Ein offener Tab dieses Fensters, in sichtbarer Tab-Leisten-Reihenfolge.
    struct Tab: Equatable {
        var id: UUID
        var projectID: UUID
        var isArchived: Bool = false
    }

    var order: [UUID] {
        switch self {
        case .grid(let order), .workspaceMap(_, let order), .project(let order):
            return order
        }
    }

    /// - Parameters:
    ///   - showsGrid: Grid dieses Fensters sichtbar (nur wirksam mit `activeWorkspace`).
    ///   - activeWorkspace: Workspace, den das Fenster referenziert (Grid sichtbar
    ///     ODER Rücksprungziel der Einzelansicht).
    ///   - openTabs: offene Tabs DIESES Fensters in Tab-Leisten-Reihenfolge.
    ///
    /// Ein Slot zählt nur, wenn seine Session hier als nicht archivierter Tab
    /// offen ist. Damit fallen leere Slots und Übernahme-Platzhalter (Tab
    /// geschlossen oder in einem anderen Fenster — beides nicht fokussierbar)
    /// heraus. Die Tab-Zugehörigkeit ist global eindeutig (`AgentUIState`),
    /// „offen in diesem Fenster" ist also gleichbedeutend mit
    /// `windowID(containingTab:) == windowID` — ohne Store-Zugriff pro Slot.
    ///
    /// Weniger als 2 Ziele → `nil` (kein Switcher; bewusst KEIN Rückfall auf
    /// eine andere Situation, sonst wechselte der Umfang je nach Belegung).
    static func resolve(
        showsGrid: Bool,
        activeWorkspace: AgentGridWorkspace?,
        selectedSessionID: UUID?,
        openTabs: [Tab]
    ) -> TabSwitcherScope? {
        // Ein Lookup über die offenen Tabs (O(Tabs)), nie ein Scan über alle
        // Sessions — läuft im Key-Event-Pfad bei jedem Schritt.
        var eligible: [UUID: Tab] = [:]
        eligible.reserveCapacity(openTabs.count)
        for tab in openTabs where !tab.isArchived && eligible[tab.id] == nil {
            eligible[tab.id] = tab
        }

        func slotOrder(_ entity: AgentGridWorkspace) -> [UUID] {
            // `normalize()` garantiert: keine Doppelung im selben Workspace.
            entity.slots.compactMap { slot in
                guard let slot, eligible[slot] != nil else { return nil }
                return slot
            }
        }

        let scope: TabSwitcherScope?
        if showsGrid, let entity = activeWorkspace {
            // A — auch ohne Selektion: das Grid IST der Umfang.
            scope = .grid(order: slotOrder(entity))
        } else if let selectedSessionID,
                  let entity = activeWorkspace,
                  entity.slots.contains(selectedSessionID) {
            // B — nur der Workspace, den DIESES Fenster referenziert. Liegt
            // der Chat in einem anderen (oder mehreren) Workspaces, ist das
            // Situation C.
            scope = .workspaceMap(workspaceID: entity.id, order: slotOrder(entity))
        } else if let selectedSessionID, let selected = eligible[selectedSessionID] {
            // C
            var seen = Set<UUID>()
            scope = .project(order: openTabs.compactMap { tab in
                guard !tab.isArchived,
                      tab.projectID == selected.projectID,
                      seen.insert(tab.id).inserted else { return nil }
                return tab.id
            })
        } else {
            scope = nil
        }

        guard let scope, scope.order.count >= 2 else { return nil }
        return scope
    }
}
