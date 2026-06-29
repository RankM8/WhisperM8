import SwiftUI

/// Multi-Select-Bulk-Aktionen fürs Kontextmenü (Tab-Leiste UND Sidebar). Eine
/// Aktion wirkt auf die GANZE Auswahl, wenn die angeklickte Session Teil davon
/// ist (≥2), sonst nur auf diese eine — Einzel- und Mehrfach-Auswahl bleiben
/// identisch verdrahtet, nur das Label zeigt die Anzahl.
///
/// Kern ist ID-basiert (Sidebar-Closures liefern UUIDs); Session-Wrapper
/// halten die Tab-Menü-Aufrufstellen knapp.
extension AgentChatsView {
    // MARK: - ID-basierter Kern

    /// Zielgruppe einer Bulk-Aktion (alle Ausgewählten bzw. nur `id`).
    func actionGroup(forID id: UUID) -> [UUID] {
        multiSelection.contains(id) && multiSelection.count > 1 ? Array(multiSelection) : [id]
    }

    /// Count-abhängiges Label (Format mit `%d`).
    func bulkLabel(_ single: String, _ pluralFormat: String, forID id: UUID) -> String {
        let count = actionGroup(forID: id).count
        return count > 1 ? String(format: pluralFormat, count) : single
    }

    /// Pin-Label inkl. Normalisierung (alle gepinnt → „<n> lösen", sonst „<n> anpinnen").
    func pinLabel(forID id: UUID) -> String {
        let group = actionGroup(forID: id)
        guard group.count > 1 else {
            return pinnedSessionIDs.contains(id) ? "Loslösen" : "Anpinnen"
        }
        let allPinned = group.allSatisfy { pinnedSessionIDs.contains($0) }
        return allPinned ? "\(group.count) lösen" : "\(group.count) anpinnen"
    }

    private func sessions(in ids: [UUID]) -> [AgentChatSession] {
        ids.compactMap { gid in workspace.sessions.first { $0.id == gid } }
    }

    /// „Tab schließen" für die Gruppe (Sessions bleiben in der Sidebar).
    func closeTabsInSelection(forID id: UUID) {
        sessions(in: actionGroup(forID: id)).forEach { closeTab($0) }
        multiSelection = []
    }

    /// „Chat schließen" (archivieren) für die Gruppe.
    func archiveSelection(forID id: UUID) {
        sessions(in: actionGroup(forID: id)).forEach { archiveSession($0) }
        multiSelection = []
    }

    /// Pin/Unpin für die Gruppe — normalisiert. Auswahl bleibt erhalten.
    func togglePinSelection(forID id: UUID) {
        let group = actionGroup(forID: id)
        guard group.count > 1 else { togglePin(id); return }
        let allPinned = group.allSatisfy { pinnedSessionIDs.contains($0) }
        for gid in group {
            if allPinned {
                unpinSession(gid)
            } else if !pinnedSessionIDs.contains(gid) {
                pinSession(gid)
            }
        }
    }

    /// Setzt die Farbe für die ganze Gruppe (`nil` = Provider-Farbe).
    func setColorForSelection(forID id: UUID, color: String?) {
        for gid in actionGroup(forID: id) { setSessionColor(id: gid, color: color) }
    }

    // MARK: - Session-Wrapper (Tab-Menü)

    func actionGroup(for session: AgentChatSession) -> [UUID] { actionGroup(forID: session.id) }
    func bulkLabel(_ single: String, _ pluralFormat: String, for session: AgentChatSession) -> String {
        bulkLabel(single, pluralFormat, forID: session.id)
    }
    func pinLabel(for session: AgentChatSession) -> String { pinLabel(forID: session.id) }
    func closeTabsInSelection(_ session: AgentChatSession) { closeTabsInSelection(forID: session.id) }
    func archiveSelection(_ session: AgentChatSession) { archiveSelection(forID: session.id) }
    func togglePinSelection(_ session: AgentChatSession) { togglePinSelection(forID: session.id) }
    func setColorForSelection(_ session: AgentChatSession, color: String?) {
        setColorForSelection(forID: session.id, color: color)
    }
}
