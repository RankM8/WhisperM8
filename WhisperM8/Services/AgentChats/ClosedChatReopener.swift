import Foundation

/// Zuletzt geschlossene Chats dieses App-Starts wieder öffnen — gemeinsam für
/// `chats reopen` (Control-Socket) und L2 + Viereck am Controller (Runde 5).
/// Grundlage ist die flüchtige Liste des `AgentWindowStore` (LIFO, höchstens
/// 20, nicht über einen Neustart).
@MainActor
enum ClosedChatReopener {
    /// Wiederöffnen geht nur für Chats, die es noch gibt und die nicht
    /// archiviert sind; gelöschte Shells fallen damit heraus.
    static func isEligible(_ sessionID: UUID, in workspace: AgentWorkspace) -> Bool {
        workspace.sessions.contains { $0.id == sessionID && $0.status != .archived }
    }

    /// Der Chat, den das nächste Wiederöffnen zurückholt, ohne die Liste zu
    /// verändern (für die Anzeige in der Insel).
    static func next(store: AgentWindowStore = .shared, workspace: AgentWorkspace? = nil) -> AgentChatSession? {
        let workspace = workspace ?? AgentWorkspaceUIModel.shared.workspace
        for entry in store.recentlyClosedTabs.reversed() {
            guard isEligible(entry.sessionID, in: workspace),
                  store.windowID(containingTab: entry.sessionID) == nil else { continue }
            return workspace.sessions.first { $0.id == entry.sessionID }
        }
        return nil
    }

    /// Öffnet den zuletzt geschlossenen Chat wieder; `nil`, wenn es keinen gibt.
    @discardableResult
    static func reopen(store: AgentWindowStore = .shared, workspace: AgentWorkspace? = nil) -> AgentChatSession? {
        let workspace = workspace ?? AgentWorkspaceUIModel.shared.workspace
        guard let reopened = store.reopenLastClosedTab(isEligible: { isEligible($0, in: workspace) }) else {
            return nil
        }
        return workspace.sessions.first { $0.id == reopened.sessionID }
    }
}
