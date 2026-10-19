import SwiftUI

/// Texte der Bestätigungsdialoge (Projekt löschen, Archivieren, Beenden).
/// Ausgelagert aus dem `body` von `AgentChatsView`: die Dialog-Ketten dort
/// stehen an der Grenze dessen, was der Swift-Typprüfer in vertretbarer Zeit
/// löst — die Berechnung der Texte gehört nicht dazu.
extension AgentChatsView {
    func projectDeleteMessage(for project: AgentProject) -> String {
        let projectSessions = workspace.sessions.filter { $0.projectID == project.id }
        let runningCount = projectSessions.filter(needsProcessEndConfirmation).count
        let runningNote = runningCount > 0
            ? " " + String(localized: "\(runningCount) of them are still running and will be stopped.")
            : ""
        return ChatsUIStrings.projectDeleteMessage(count: projectSessions.count) + runningNote
    }

    func archiveMessage(for sessions: [AgentChatSession]) -> String {
        let running = sessions.filter { terminalRegistry.controller(for: $0.id)?.isRunning == true }.count
        let shellNote = sessions.contains(where: \.isTerminal)
            ? " " + String(localized: "Shell terminals are closed for good and cannot be restored.")
            : ""
        return ChatsUIStrings.archiveMessage(running: running, total: sessions.count) + shellNote
    }

    func endMessage(for pending: SessionEndRequest) -> String {
        let sessions = pending.sessions
        let running = sessions.filter { terminalRegistry.controller(for: $0.id)?.isRunning == true }.count
        // Minus der Workspace-Sektion: das zusätzliche Entfernen aus dem
        // Workspace gehört benannt (siehe `ChatsUIStrings.endMessage`).
        let shellNote = sessions.contains(where: \.isTerminal)
            ? " " + String(localized: "Shell terminals are closed for good and cannot be restored.")
            : ""
        return ChatsUIStrings.endMessage(
            running: running, total: sessions.count, workspaceName: pending.removeFromWorkspace?.name
        ) + shellNote
    }
}
