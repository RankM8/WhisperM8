import Foundation

// MARK: - Position eines Chats (Feld `order` in `chats list/show --json`)

/// Wo ein Chat steht: Position in der Projektgruppe der Seitenleiste
/// (1-basiert; `null` für archivierte, gepinnte, Subagent-Kinder und nicht von
/// Hand angelegte, die dort nicht stehen) samt rohem `sortIndex`, dazu seine Tabs je Fenster
/// (1-basiert). Gelesen von Disk wie alle Lesebefehle; die App schreibt
/// gebündelt, der Stand kann Sekunden hinterherhinken.
enum ChatsOrderInfo {
    static func byID(workspace: AgentWorkspace, uiState: AgentUIState?) -> [UUID: [String: Any]] {
        let pinned = Set(uiState?.pinnedSessionIDs ?? [])
        var result: [UUID: [String: Any]] = [:]
        for session in workspace.sessions {
            result[session.id] = [
                "sortIndex": session.sortIndex.map { $0 as Any } ?? NSNull(),
                "sidebarPosition": NSNull(),
                "tabs": [[String: Any]](),
            ]
        }
        let groups = AgentControlRequestHandler.sidebarSessions(workspace: workspace, pinnedIDs: pinned)
        for (_, sessions) in groups {
            for (index, session) in sessions.enumerated() {
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
