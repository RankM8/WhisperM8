import SwiftUI

/// Eigene Seite der CLAUDE-CODE-Sektion (IA-Umbau 2026-07-19). Der Inhalt
/// lebt weiterhin in `AgentChatsClaudeAccountsTab` — hier nur der
/// Seiten-Rahmen, damit Accounts nicht mehr als Tab in „Agent Chats"
/// versteckt sind.
struct ClaudeAccountsSettingsPage: View {
    var body: some View {
        SettingsPageContainer(
            title: "Accounts",
            subtitle: "Claude accounts as separate profiles (CLAUDE_CONFIG_DIR). Sessions are stamped with their account and resume under it."
        ) {
            AgentChatsClaudeAccountsTab()
        }
    }
}
