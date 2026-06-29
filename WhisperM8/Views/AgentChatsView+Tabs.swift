import AppKit
import SwiftUI

/// Tab-Verwaltung der AgentChatsView: Tab oeffnen/schliessen, Chat
/// archivieren, Tab-Reorder per Drag (dropTab/dropTabAtEnd), Multi-Select +
/// Tear-off (moveSelectionToNewWindow/detachDroppedToNewWindow). Aus
/// AgentChatsView.swift ausgelagert (Phase-2-Split).
extension AgentChatsView {
    /// Tab-Klick mit Modifier-Semantik (Browser-/Finder-artig): Cmd toggelt,
    /// Shift wählt einen Bereich, sonst Einzel-Auswahl. `selectedSessionID`
    /// bleibt der aktive (angezeigte) Tab; `multiSelection` hält die Gruppe.
    func handleTabClick(_ id: UUID) {
        let mods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let outcome: TabSelectionOutcome
        if mods.contains(.command) {
            outcome = TabSelectionResolver.commandClick(id, active: selectedSessionID, selection: multiSelection)
        } else if mods.contains(.shift) {
            outcome = TabSelectionResolver.shiftClick(id, anchor: selectedSessionID, order: headerTabs.map(\.id))
        } else {
            outcome = TabSelectionResolver.click(id)
        }
        selectedSessionID = outcome.active
        multiSelection = outcome.selection
    }

    /// Sidebar-Klick mit Modifier-Semantik: Cmd toggelt / Shift wählt einen
    /// Bereich (innerhalb des Projekts) in `multiSelection` — OHNE Tab zu öffnen
    /// oder den aktiven Tab zu wechseln (reine Auswahl für Gruppen-Aktionen).
    /// Normaler Klick = bisheriges Verhalten (öffnen + aktiv + Einzel-Auswahl).
    func handleSidebarSessionClick(_ sessionID: UUID, project: AgentProject, orderedSessionIDs: [UUID]) {
        let mods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) {
            multiSelection = TabSelectionResolver.commandClick(sessionID, active: selectedSessionID, selection: multiSelection).selection
        } else if mods.contains(.shift) {
            multiSelection = TabSelectionResolver.shiftClick(sessionID, anchor: selectedSessionID, order: orderedSessionIDs).selection
        } else {
            selectedProjectID = project.id
            expandedProjectIDs.insert(project.id)
            openTab(sessionID)
            selectedSessionID = sessionID
            multiSelection = []
            AppPreferences.shared.agentDefaultProjectPath = project.path
        }
    }

    /// Wie `handleSidebarSessionClick`, aber für Zeilen ohne festes Projekt
    /// (gepinnt/flach): Cmd toggelt, Shift wählt einen Bereich in `order`,
    /// normaler Klick führt `plainClick` aus + leert die Auswahl.
    func handleSidebarRowClick(_ sessionID: UUID, order: [UUID], plainClick: () -> Void) {
        let mods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) {
            multiSelection = TabSelectionResolver.commandClick(sessionID, active: selectedSessionID, selection: multiSelection).selection
        } else if mods.contains(.shift) {
            multiSelection = TabSelectionResolver.shiftClick(sessionID, anchor: selectedSessionID, order: order).selection
        } else {
            plainClick()
            multiSelection = []
        }
    }

    /// Die mitzuziehende Gruppe für den Drag von `session`: alle ausgewählten
    /// OFFENEN Tabs in Anzeige-Reihenfolge, falls `session` Teil der Auswahl ist;
    /// sonst leer (Einzel-Drag).
    func tabDragGroup(for session: AgentChatSession) -> [UUID] {
        multiSelection.contains(session.id) ? openTabIDs.filter { multiSelection.contains($0) } : []
    }

    /// Öffnet einen Tab in der globalen Bar (ans Ende), falls noch nicht
    /// offen. Kein Persistenz-Cap zur Laufzeit — die Bar scrollt; gekappt
    /// wird beim nächsten Load (`AgentUIState.prune`).
    func openTab(_ id: UUID) {
        guard !openTabIDs.contains(id) else { return }
        openTabIDs.append(id)
    }

    /// Schließt nur den TAB — die Session bleibt in der Sidebar erhalten
    /// und ein laufendes PTY läuft weiter (Status bleibt über den
    /// Sidebar-Dot sichtbar; erneutes Öffnen attached an denselben
    /// Terminal-Controller inkl. Scrollback).
    func closeTab(_ session: AgentChatSession) {
        // Geschlossener Tab darf nicht in der Mehrfach-Auswahl zurückbleiben.
        multiSelection.remove(session.id)
        guard let index = openTabIDs.firstIndex(of: session.id) else {
            if selectedSessionID == session.id { selectedSessionID = openTabIDs.first }
            return
        }
        openTabIDs.remove(at: index)
        if selectedSessionID == session.id {
            // Nachbar-Tab selektieren (gleiche Position, sonst letzter).
            selectedSessionID = openTabIDs.indices.contains(index)
                ? openTabIDs[index]
                : openTabIDs.last
        }
    }

    /// Chat vollständig schließen: Terminal terminieren (falls läuft) und
    /// Session archivieren — dadurch verschwindet sie aus Tab-Bar UND
    /// Sidebar. Daten bleiben in der Workspace-Datei erhalten.
    func archiveSession(_ session: AgentChatSession) {
        if terminalRegistry.controller(for: session.id)?.isRunning == true {
            terminalRegistry.terminate(sessionID: session.id)
        }

        do {
            try store.updateSession(id: session.id) { $0.status = .archived }
        } catch {
            errorMessage = error.localizedDescription
        }

        pinnedSessionIDs.removeAll { $0 == session.id }
        closeTab(session)
    }

    /// Reordert die globale Tab-Bar: `dropped` landet vor `targetID`.
    /// Kommt der Drag aus der Sidebar (Session ohne offenen Tab), wird der
    /// Tab an der Drop-Position geöffnet.
    func dropTab(_ dropped: DraggableSession, before targetID: UUID) {
        let id = dropped.sessionID
        guard id != targetID else { return }
        // Cross-Window-Move ODER lokaler Reorder/Sidebar-Open — der Store
        // erledigt beides (moveTab fuegt nicht-offene Tabs an der Drop-Position
        // ein und selektiert sie). Persistenz + Invarianten inklusive.
        let source = dropped.sourceWindowID ?? windowID
        windowStore.moveTab(id, from: source, to: windowID, before: targetID)
    }

    func dropTabAtEnd(_ dropped: DraggableSession) {
        let id = dropped.sessionID
        let source = dropped.sourceWindowID ?? windowID
        windowStore.moveTab(id, from: source, to: windowID, before: nil)
    }

    /// Multi-select-bewusstes „in neues Fenster": ist `session` Teil der
    /// Auswahl, wandert die GANZE Gruppe (Anzeige-Reihenfolge erhalten) in EIN
    /// neues Fenster. Der erste Tab eröffnet das Fenster, die restlichen werden
    /// hineinverschoben. PTYs bleiben (Registry ist sessionID-basiert).
    func moveSelectionToNewWindow(_ session: AgentChatSession) {
        let group = multiSelection.contains(session.id)
            ? openTabIDs.filter { multiSelection.contains($0) }
            : [session.id]
        guard let first = group.first, openTabIDs.contains(first) else { return }
        let newWindowID = windowStore.detachToNewWindow(first, from: windowID)
        for id in group.dropFirst() where openTabIDs.contains(id) {
            windowStore.moveTab(id, from: windowID, to: newWindowID, before: nil)
        }
        multiSelection = []
        DispatchQueue.main.async {
            openWindow(id: WindowRequest.agentChatWindowGroupID, value: newWindowID)
        }
    }

    /// Tear-off-Drop: erzeugt EIN neues Fenster mit der gezogenen Session bzw.
    /// (wenn sie Teil der Quell-Auswahl ist) der ganzen Gruppe. Liest die Auswahl
    /// LIVE aus dem Quell-Fenster (robust, kein Payload-Round-Trip).
    func detachDroppedToNewWindow(_ dropped: DraggableSession) {
        let source = dropped.sourceWindowID ?? windowID
        let sel = windowStore.multiSelection(in: source)
        let group = (sel.count > 1 && sel.contains(dropped.sessionID))
            ? windowStore.openTabIDs(in: source).filter { sel.contains($0) }
            : [dropped.sessionID]
        guard let first = group.first, windowStore.openTabIDs(in: source).contains(first) else { return }
        let newWindowID = windowStore.detachToNewWindow(first, from: source)
        for id in group.dropFirst() {
            windowStore.moveTab(id, from: source, to: newWindowID, before: nil)
        }
        windowStore.setMultiSelection([], in: source)
        DispatchQueue.main.async {
            openWindow(id: WindowRequest.agentChatWindowGroupID, value: newWindowID)
        }
    }
}
