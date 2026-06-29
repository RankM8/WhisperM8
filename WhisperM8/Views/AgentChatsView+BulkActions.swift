import SwiftUI

/// Multi-Select-Bulk-Aktionen fürs Kontextmenü. Eine Aktion wirkt auf die GANZE
/// Auswahl, wenn die angeklickte Session Teil davon ist (≥2), sonst nur auf
/// diese eine — so bleiben Einzel- und Mehrfach-Auswahl identisch verdrahtet,
/// nur das Label zeigt die Anzahl. Auswahl/aktiver Tab folgen dem in der
/// AskUserQuestion bestätigten Modell.
extension AgentChatsView {
    /// Zielgruppe einer Bulk-Aktion (alle Ausgewählten bzw. nur `session`).
    func actionGroup(for session: AgentChatSession) -> [UUID] {
        multiSelection.contains(session.id) && multiSelection.count > 1
            ? Array(multiSelection)
            : [session.id]
    }

    /// Count-abhängiges Label: Einzel-Text oder „<n> …" (Format mit `%d`).
    func bulkLabel(_ single: String, _ pluralFormat: String, for session: AgentChatSession) -> String {
        let count = actionGroup(for: session).count
        return count > 1 ? String(format: pluralFormat, count) : single
    }

    /// Pin-Label inkl. Normalisierung: alle gepinnt → „<n> lösen", sonst
    /// „<n> anpinnen" (Einzel: „Loslösen"/„Anpinnen").
    func pinLabel(for session: AgentChatSession) -> String {
        let group = actionGroup(for: session)
        guard group.count > 1 else {
            return pinnedSessionIDs.contains(session.id) ? "Loslösen" : "Anpinnen"
        }
        let allPinned = group.allSatisfy { pinnedSessionIDs.contains($0) }
        return allPinned ? "\(group.count) lösen" : "\(group.count) anpinnen"
    }

    private func sessions(in group: [UUID]) -> [AgentChatSession] {
        group.compactMap { id in workspace.sessions.first { $0.id == id } }
    }

    /// „Tab schließen" für die Gruppe (Sessions bleiben in der Sidebar).
    func closeTabsInSelection(_ session: AgentChatSession) {
        sessions(in: actionGroup(for: session)).forEach { closeTab($0) }
        multiSelection = []
    }

    /// „Chat schließen" (archivieren) für die Gruppe.
    func archiveSelection(_ session: AgentChatSession) {
        sessions(in: actionGroup(for: session)).forEach { archiveSession($0) }
        multiSelection = []
    }

    /// Pin/Unpin für die Gruppe — normalisiert (alle gepinnt → lösen, sonst
    /// anpinnen). Auswahl bleibt erhalten.
    func togglePinSelection(_ session: AgentChatSession) {
        let group = actionGroup(for: session)
        guard group.count > 1 else { togglePin(session.id); return }
        let allPinned = group.allSatisfy { pinnedSessionIDs.contains($0) }
        for id in group {
            if allPinned {
                unpinSession(id)
            } else if !pinnedSessionIDs.contains(id) {
                pinSession(id)
            }
        }
    }

    /// Setzt die Tab-Farbe für die ganze Gruppe (`nil` = Provider-Farbe).
    func setColorForSelection(_ session: AgentChatSession, color: String?) {
        for id in actionGroup(for: session) { setSessionColor(id: id, color: color) }
    }
}
