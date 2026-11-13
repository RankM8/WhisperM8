import Foundation

// MARK: - Position eines Chats (Feld `order` in `chats list/show --json`)

/// Wo ein Chat steht: Position in der Seitenleiste seines Projekts (1-basiert,
/// archivierte haben keine) samt rohem `sortIndex`, dazu seine Tabs je Fenster
/// (1-basiert). Gelesen von Disk wie alle Lesebefehle; die App schreibt
/// gebündelt, der Stand kann Sekunden hinterherhinken.
enum ChatsOrderInfo {
    static func byID(workspace: AgentWorkspace, uiState: AgentUIState?) -> [UUID: [String: Any]] {
        var result: [UUID: [String: Any]] = [:]
        for session in workspace.sessions {
            result[session.id] = [
                "sortIndex": session.sortIndex.map { $0 as Any } ?? NSNull(),
                "sidebarPosition": NSNull(),
                "tabs": [[String: Any]](),
            ]
        }
        for (_, sessions) in Dictionary(grouping: workspace.sessions, by: \.projectID) {
            let visible = AgentSessionStore.sortedSessions(sessions.filter { $0.status != .archived })
            for (index, session) in visible.enumerated() {
                result[session.id]?["sidebarPosition"] = index + 1
            }
        }
        for window in uiState?.windows ?? [] {
            for (index, id) in window.openTabIDs.enumerated() where result[id] != nil {
                var tabs = result[id]?["tabs"] as? [[String: Any]] ?? []
                tabs.append(["windowID": window.id.uuidString, "position": index + 1])
                result[id]?["tabs"] = tabs
            }
        }
        return result
    }
}
