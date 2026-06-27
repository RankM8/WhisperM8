import SwiftUI

/// Tab-Verwaltung der AgentChatsView: Tab oeffnen/schliessen, Chat
/// archivieren, Tab-Reorder per Drag (dropTab/dropTabAtEnd/shouldDetachTab)
/// und Tab in neues Fenster abloesen. Aus AgentChatsView.swift ausgelagert
/// (Phase-2-Split).
extension AgentChatsView {
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

    func shouldDetachTab(for value: DragGesture.Value) -> Bool {
        // Detach nur bei klar vertikalem Herausziehen aus der Leiste — so
        // kollidiert die Geste nicht mit dem horizontalen Reorder (.draggable),
        // der sonst fälschlich ein neues Fenster aufmachte.
        abs(value.translation.height) > 60 && abs(value.translation.width) < 44
    }

    func moveTabToNewWindow(_ session: AgentChatSession) {
        // Tab muss in DIESEM Fenster offen sein — sonst (z. B. Detach-Geste
        // feuerte nach einem bereits erfolgten Cross-Window-Drop) nichts tun.
        guard openTabIDs.contains(session.id) else { return }
        let newWindowID = windowStore.detachToNewWindow(session.id, from: windowID)
        // Fenster-Erzeugung aus dem synchronen Gesten-Stack lösen: openWindow
        // direkt in DragGesture.onEnded kann SwiftUI/AppKit beim Aufbau der
        // neuen Scene destabilisieren (beobachteter Detach-Crash).
        DispatchQueue.main.async {
            openWindow(id: WindowRequest.agentChatWindowGroupID, value: newWindowID)
        }
    }
}
