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
        guard multiSelection.contains(id), multiSelection.count > 1 else { return [id] }
        return Self.orderedSelection(multiSelection, visualOrder: visualTabOrderIDs)
    }

    /// Auswahl in der sichtbaren Tab-Reihenfolge, Ausgewählte ohne Tab dahinter
    /// (stabil sortiert). Ein Set hat keine Ordnung — Mehrfach-Anpinnen
    /// vertauschte sonst die Reihenfolge und wechselte sie zwischen Starts
    /// (LR-AU-012).
    static func orderedSelection(_ selection: Set<UUID>, visualOrder: [UUID]) -> [UUID] {
        let inTabs = visualOrder.filter(selection.contains)
        let rest = selection.subtracting(inTabs).sorted { $0.uuidString < $1.uuidString }
        return inTabs + rest
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
            return pinnedSessionIDs.contains(id) ? String(localized: "Unpin") : String(localized: "Pin")
        }
        let unpin = TabSelectionResolver.shouldUnpinGroup(group, pinned: Set(pinnedSessionIDs))
        return unpin ? String(localized: "Unpin \(group.count)") : String(localized: "Pin \(group.count)")
    }

    /// Sessions zu `ids` in deren Reihenfolge — EIN Durchlauf über den
    /// Workspace statt einem `first(where:)` pro ID. Läuft auch im
    /// Kontextmenü-Bau (pro Zeile und Render).
    func sessions(in ids: [UUID]) -> [AgentChatSession] {
        guard !ids.isEmpty else { return [] }
        let wanted = Set(ids)
        var byID: [UUID: AgentChatSession] = [:]
        for session in workspace.sessions where wanted.contains(session.id) && byID[session.id] == nil {
            byID[session.id] = session
            if byID.count == wanted.count { break }
        }
        return ids.compactMap { byID[$0] }
    }

    /// „Tab schließen" für die Gruppe (Sessions bleiben in der Sidebar).
    func closeTabsInSelection(forID id: UUID) {
        sessions(in: actionGroup(forID: id)).forEach { closeTab($0) }
        multiSelection = []
    }

    /// „Archivieren" für die Gruppe. Läuft über `requestArchive`, das bei
    /// laufenden Terminals einen Bestätigungsdialog vorschaltet — der
    /// Auswahl-Reset passiert erst in `commitArchive` (Abbrechen behält die
    /// Mehrfach-Auswahl).
    func archiveSelection(forID id: UUID) {
        requestArchive(sessions(in: actionGroup(forID: id)))
    }

    /// Hover-Aktion der Sidebar-Zeile für die Gruppe: im Scope „Aktiv" wird
    /// beendet (Tab zu, Terminal gestoppt, kein Archiv-Eintrag), sonst
    /// archiviert — `performSidebarCloseAction` entscheidet. Der Auswahl-Reset
    /// passiert wie beim Archivieren erst beim Commit.
    func closeSelectionFromSidebar(forID id: UUID) {
        performSidebarCloseAction(sessions(in: actionGroup(forID: id)))
    }

    /// Pin/Unpin für die Gruppe — normalisiert. Auswahl bleibt erhalten.
    func togglePinSelection(forID id: UUID) {
        let group = actionGroup(forID: id)
        guard group.count > 1 else { togglePin(id); return }
        let unpin = TabSelectionResolver.shouldUnpinGroup(group, pinned: Set(pinnedSessionIDs))
        for gid in group {
            if unpin {
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
    /// „Archivieren"-Label, Terminal-bewusst: Terminals werden geschlossen
    /// statt archiviert (`requestArchive` teilt auf) — das Label sagt das
    /// ehrlich, auch bei gemischter Bulk-Auswahl.
    func archiveLabel(for session: AgentChatSession) -> String {
        let ids = actionGroup(forID: session.id)
        // Einzelfall ohne Workspace-Lookup — läuft pro Zeile und Render.
        let group = ids.count > 1 ? sessions(in: ids) : []
        guard group.count > 1 else {
            return session.isTerminal ? String(localized: "Close terminal") : String(localized: "Archive")
        }
        let terminals = group.filter(\.isTerminal).count
        if terminals == 0 { return String(localized: "Archive \(group.count) chats") }
        if terminals == group.count { return String(localized: "Close \(group.count) terminals") }
        return String(localized: "Close/archive \(group.count)")
    }
    /// Icon zum `archiveLabel` (einzelnes Terminal → X statt Archivbox).
    func archiveIcon(for session: AgentChatSession) -> String {
        session.isTerminal && actionGroup(forID: session.id).count == 1 ? "xmark.circle" : "archivebox"
    }
    func pinLabel(for session: AgentChatSession) -> String { pinLabel(forID: session.id) }
    func closeTabsInSelection(_ session: AgentChatSession) { closeTabsInSelection(forID: session.id) }
    func archiveSelection(_ session: AgentChatSession) { archiveSelection(forID: session.id) }
    func togglePinSelection(_ session: AgentChatSession) { togglePinSelection(forID: session.id) }
    func setColorForSelection(_ session: AgentChatSession, color: String?) {
        setColorForSelection(forID: session.id, color: color)
    }
}
