import Foundation

/// Wohin eine Chat-Zeile im WORKSPACES-Abschnitt der Seitenleiste führt. Pur,
/// damit die Regeln ohne Fenster testbar sind; ausgeführt in
/// `AgentChatsView.openWorkspaceChatRow`.
///
/// Entscheidung des Nutzers nach Runde 3: Den Workspace wechselt nur Kreuz am
/// Controller. Der Mausklick folgt der quellenunabhängigen Klickregel wie vor
/// Runde 3 (im sichtbaren Workspace Kachel-Fokus, sonst Einzelansicht).
enum WorkspaceChatRowRoute: Equatable {
    /// Klickregel: `selectedSessionID = id`.
    case select
    /// In den Workspace der Zeile wechseln, der Chat bekommt den Kachel-Fokus
    /// (`AgentWindowStore.navigateToWorkspaceChat`).
    case enterWorkspace

    enum Source: Equatable {
        case mouse, controller
    }

    static func route(for source: Source) -> WorkspaceChatRowRoute {
        switch source {
        case .mouse: return .select
        case .controller: return .enterWorkspace
        }
    }

    /// Ergebnis von `navigateToWorkspaceChat`: Hat das Fenster den Workspace
    /// gezeigt, ist alles getan. Bei einem Konflikt (ein anderes Fenster
    /// besitzt den Workspace, seine Chats sind Tabs anderer Fenster) und bei
    /// einer veralteten Zeile gilt die Klickregel — sonst käme nur ein anderes
    /// Fenster nach vorn, und der Chat wäre nirgends gewählt.
    static func fallsBackToSelect(after result: GridActivationResult) -> Bool {
        switch result {
        case .activated, .alreadyActiveHere: return false
        case .alreadyActive, .blockedByWindowOwnership, .rejected: return true
        }
    }
}
