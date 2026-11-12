import Foundation

/// Zeilen der Controller-Insel aus Workspace und Status. Pur bis auf
/// `live`, das die Stores der App liest — nur im Ereignis-Pfad, wenn „Wohin“
/// aufgeht, nie in einem Body.
enum ControllerIslandRows {
    static func status(_ status: AgentSessionRuntimeStatus?) -> ControllerIslandStatus? {
        switch status {
        case .working: return .working
        case .awaitingInput: return .awaiting
        case .idle: return .idle
        case .errored: return .errored
        case .stopped: return .stopped
        case nil: return nil
        }
    }

    /// Rechts in der Zeile: „wartet · 2 min“, „arbeitet · 6 min“, „bereit“,
    /// „Fehler“; beim aktuellen Chat „jetzt“. Wörter und Dauer wie Tab-Switcher
    /// und Notch (`TabSwitcherTileModel.elapsed`); bei ruhenden Chats ohne
    /// „vor …“, damit die Spalte schmal bleibt.
    static func detail(
        status: AgentSessionRuntimeStatus?, statusSince: Date?, isCurrent: Bool, now: Date
    ) -> String {
        if isCurrent { return String(localized: "now") }
        func running(_ word: String) -> String {
            guard let statusSince else { return word }
            return "\(word) · \(TabSwitcherTileModel.elapsed(now.timeIntervalSince(statusSince)))"
        }
        switch status {
        case .working: return running(String(localized: "working"))
        case .awaitingInput: return running(String(localized: "waiting"))
        case .idle: return String(localized: "ready")
        case .errored: return String(localized: "Error")
        case .stopped, nil: return String(localized: "stopped")
        }
    }

    /// Zeilen in der Reihenfolge `order` (die der Liste links). Chats, die der
    /// Workspace nicht kennt, fallen weg.
    static func chatRows(
        order: [UUID], current: UUID?, workspace: AgentWorkspace,
        status: (UUID) -> AgentSessionRuntimeStatus?, statusSince: (UUID) -> Date?, now: Date
    ) -> [ControllerIslandChatRow] {
        let sessions = Dictionary(workspace.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let projects = Dictionary(workspace.projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { id in
            guard let session = sessions[id] else { return nil }
            let runtime = status(id)
            return ControllerIslandChatRow(
                id: id, title: session.title, project: projects[session.projectID],
                status: Self.status(runtime),
                detail: detail(status: runtime, statusSince: statusSince(id), isCurrent: id == current, now: now),
                isCurrent: id == current)
        }
    }

    @MainActor
    static func chatRows(order: [UUID], current: UUID?) -> [ControllerIslandChatRow] {
        let coordinator = AgentSessionStatusCoordinator.shared
        return chatRows(
            order: order, current: current, workspace: AgentWorkspaceUIModel.shared.workspace,
            status: { coordinator.statusStore.status(for: $0) },
            statusSince: { coordinator.activityStore.statusSince(for: $0) },
            now: Date())
    }
}
