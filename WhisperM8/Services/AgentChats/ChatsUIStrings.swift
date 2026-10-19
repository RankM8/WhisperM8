import Foundation

/// Zählabhängige Texte der Chat-Oberfläche (Singular/Plural) an einer Stelle —
/// Englisch im Code, Deutsch im String-Katalog (E1). Zwei Schlüssel statt
/// Katalog-Variationen, damit der Guard sie als einfache Schlüssel prüfen kann.
enum ChatsUIStrings {
    /// „N Chats laufen als Tab in einem anderen Fenster" (Workspace-/Grid-Konflikte).
    static func runningInOtherWindow(count: Int) -> String {
        count == 1
            ? String(localized: "1 chat is running as a tab in another window")
            : String(localized: "\(count) chats are running as tabs in another window")
    }

    /// „N Chat(s) bleiben" im Löschdialog eines Workspaces/Projekts.
    static func chatCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 chat") : String(localized: "\(count) chats")
    }

    // MARK: - Bestätigungsdialoge der Chat-Oberfläche

    /// Bestätigungs-Button des Archiv-Dialogs.
    static func archiveButton(count: Int) -> String {
        count == 1 ? String(localized: "Archive") : String(localized: "Archive \(count) chats")
    }

    /// Bestätigungs-Button des Beenden-Dialogs.
    static func endButton(count: Int) -> String {
        count == 1 ? String(localized: "End") : String(localized: "End \(count) chats")
    }

    /// Text unter „Workspace löschen?".
    static func workspaceDeleteMessage(name: String, count: Int) -> String {
        count == 1
            ? String(localized: "Removes only the group “\(name)” — its 1 chat stays, with its tabs and running processes.")
            : String(localized: "Removes only the group “\(name)” — its \(count) chats stay, with their tabs and running processes.")
    }

    /// Text unter „Projekt löschen?" (ohne Hinweis auf laufende Chats).
    static func projectDeleteMessage(count: Int) -> String {
        count == 1
            ? String(localized: "Removes the project and its 1 chat from WhisperM8. The repo on disk and the Claude/Codex transcripts stay untouched.")
            : String(localized: "Removes the project and its \(count) chats from WhisperM8. The repo on disk and the Claude/Codex transcripts stay untouched.")
    }

    /// Text unter „Chat archivieren?".
    static func archiveMessage(running: Int, total: Int) -> String {
        total == 1
            ? String(localized: "The chat is still running — archiving ends the terminal. The chat stays in the archive and can be restored.")
            : String(localized: "\(running) of \(total) chats are still running — archiving ends the terminals. All chats stay in the archive and can be restored.")
    }

    /// Text unter „Chat beenden?"; `workspaceName` = zusätzliches Entfernen aus dem Workspace.
    static func endMessage(running: Int, total: Int, workspaceName: String?) -> String {
        guard total == 1 else {
            return String(localized: "\(running) of \(total) chats are still running — ending stops the terminals and closes the tabs. Nothing is archived; all chats can be resumed via “Recent”.")
        }
        let removal = workspaceName.map { String(localized: " The chat is also removed from the workspace “\($0)”.") } ?? ""
        return String(localized: "The chat is still running — ending stops the terminal and closes the tab.") + removal
            + " " + String(localized: "The chat is not archived and can be resumed via “Recent”.")
    }
}

/// Tooltip der „N fertig"-Fußzeile unter den Subagent-Kindern.
enum SubagentFooterHelp {
    static func text(done: Int, unread: Int, isExpanded: Bool) -> String {
        switch (unread > 0, isExpanded) {
        case (true, true): return String(localized: "\(done) finished subagents · \(unread) unread — click to collapse")
        case (true, false): return String(localized: "\(done) finished subagents · \(unread) unread — click to show")
        case (false, true): return String(localized: "\(done) finished subagents — click to collapse")
        case (false, false): return String(localized: "\(done) finished subagents — click to show")
        }
    }
}
