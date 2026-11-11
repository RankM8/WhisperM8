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

    /// Startzeile beim Wechsel in die Liste: die Chat-Zeile der Session (unter
    /// ihrem Projekt), sonst ihre Zeile unter einem Workspace, sonst die erste Zeile.
    mutating func start(at sessionID: UUID?) {
        if let sessionID {
            if rows.contains(.chat(sessionID)) {
                marked = .chat(sessionID)
                return
            }
            if let row = rows.first(where: {
                if case let .workspaceChat(session, _) = $0 { return session == sessionID }
                return false
            }) {
                marked = row
                return
            }
        }
        marked = rows.first
    }
}
