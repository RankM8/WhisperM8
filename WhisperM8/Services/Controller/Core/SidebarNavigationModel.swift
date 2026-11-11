import Foundation

/// Eine sichtbare Zeile der Liste links (Plan 3.5).
enum SidebarNavigationRow: Hashable, Sendable {
    case workspace(UUID)
    /// Chat unter einem Workspace.
    case workspaceChat(session: UUID, workspace: UUID)
    case project(UUID)
    /// Chat unter einem Projekt.
    case chat(UUID)
}

/// Markierung in der Liste links. Pur: bekommt die sichtbaren Zeilen in
/// Anzeige-Reihenfolge und bewegt die Markierung darüber.
struct SidebarNavigationModel: Equatable, Sendable {
    private(set) var rows: [SidebarNavigationRow] = []
    var marked: SidebarNavigationRow?

    init(rows: [SidebarNavigationRow] = [], marked: SidebarNavigationRow? = nil) {
        self.rows = rows
        self.marked = marked.flatMap { rows.contains($0) ? $0 : nil }
    }

    /// Übernimmt neue Zeilen und hält die Markierung. Ist die markierte Zeile
    /// verschwunden, rückt die Zeile an derselben Position nach (am Ende die
    /// letzte). Leere Liste → keine Markierung.
    mutating func setRows(_ newRows: [SidebarNavigationRow]) {
        let previousIndex = marked.flatMap { rows.firstIndex(of: $0) }
        rows = newRows
        guard let current = marked else { return }
        guard !newRows.isEmpty else {
            marked = nil
            return
        }
        if newRows.contains(current) { return }
        let index = min(previousIndex ?? 0, newRows.count - 1)
        marked = newRows[index]
    }

    /// Bewegt die Markierung ohne Umlauf; am Rand bleibt sie stehen. Ohne
    /// Markierung beginnt sie bei der ersten Zeile.
    mutating func move(_ step: Int) {
        guard !rows.isEmpty else {
            marked = nil
            return
        }
        guard let current = marked, let index = rows.firstIndex(of: current) else {
            marked = rows.first
            return
        }
        marked = rows[min(max(index + step, 0), rows.count - 1)]
    }

    /// Startzeile beim Wechsel in die Liste: die Zeile der Session unter einem
    /// Workspace, sonst ihre Chat-Zeile (unter dem Projekt), sonst die erste
    /// Zeile. Ist der Workspace zugeklappt, fehlt seine Zeile — dann greift die
    /// Chat-Zeile.
    mutating func start(at sessionID: UUID?) {
        marked = sessionID.flatMap { Self.preferredRow(of: $0, in: rows) } ?? rows.first
    }

    /// Zeile, für die ein Chat steht: zuerst unter einem Workspace, dann
    /// unter seinem Projekt (Handtest 11.11.2026: Wer im Workspace arbeitet,
    /// will dort weitergehen).
    static func preferredRow(of sessionID: UUID, in rows: [SidebarNavigationRow]) -> SidebarNavigationRow? {
        if let row = rows.first(where: { $0.sessionID == sessionID && $0.isWorkspaceChat }) { return row }
        return rows.contains(.chat(sessionID)) ? .chat(sessionID) : nil
    }
}

extension SidebarNavigationRow {
    /// Chat dieser Zeile; `nil` bei Kopfzeilen (Workspace, Projekt).
    var sessionID: UUID? {
        switch self {
        case let .chat(id), let .workspaceChat(id, _): return id
        case .workspace, .project: return nil
        }
    }

    var isWorkspaceChat: Bool {
        if case .workspaceChat = self { return true }
        return false
    }
}

/// Reihenfolge der Chats in der Liste links, für den Controller: Stick hoch
/// und runter in der Einzelansicht und L1/R1 im Inhalt (Handtest 11.11.2026).
/// Pur. Jeder Chat zählt einmal, an seiner ersten Stelle — Workspaces stehen
/// in der Liste vor den Projekten, ihre Zeile gewinnt also. Kopfzeilen zählen
/// nicht, es gibt keinen Umlauf.
enum SidebarChatOrder {
    /// Chats in Anzeige-Reihenfolge, jeder einmal.
    static func sessions(in rows: [SidebarNavigationRow]) -> [UUID] {
        var seen = Set<UUID>()
        return rows.compactMap(\.sessionID).filter { seen.insert($0).inserted }
    }

    /// Nachbar des aktuellen Chats um `step`; `nil` am Rand. Steht der
    /// aktuelle Chat nicht (mehr) in der Liste, beginnt es vorn (`step` > 0)
    /// bzw. hinten.
    static func neighbor(of current: UUID?, step: Int, in rows: [SidebarNavigationRow]) -> UUID? {
        let order = sessions(in: rows)
        guard step != 0, !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else {
            return step > 0 ? order.first : order.last
        }
        let target = index + step
        return order.indices.contains(target) ? order[target] : nil
    }
}
