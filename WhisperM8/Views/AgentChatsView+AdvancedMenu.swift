import SwiftUI

/// Inhalt des „+"-Menüs für neue Chats (LR-AU-031). Welche Einträge es gibt,
/// entscheidet der pure `NewChatMenuPlan`; hier hängen nur die Aktionen dran.
/// Ohne den Schalter „Advanced agent features" stehen nur Claude, Codex (und
/// bei aktivem GPT-Backend der GPT-Chat) im Menü; mit Schalter kommen Terminal
/// und das Untermenü „Advanced" (Hintergrund-Agent, Agent View, Sub-Agent-
/// Bibliothek) dazu.
extension AgentChatsView {
    @ViewBuilder
    var newChatMenuContent: some View {
        let items = NewChatMenuPlan.items(
            advancedEnabled: advancedFeaturesEnabled,
            gptBackendEnabled: AppPreferences.shared.claudeGPTBackendEnabled
        )
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            switch item {
            case .claudeChat:
                Button("New Claude chat") { createSession(provider: .claude) }
            case .codexChat:
                Button("New Codex chat") { createSession(provider: .codex) }
            case .gptChat:
                // Claude-Code-Chat mit GPT als Hauptmodell, nur für diesen Chat —
                // der gespeicherte /model-Default bleibt.
                Button("New GPT chat") { createSession(provider: .claude, gptMainModel: true) }
            case .terminal:
                // Kein Agent: normale Login-Shell im Projektverzeichnis. Der Provider
                // ist nur Schema-Platzhalter (siehe AgentSessionKind.terminal).
                Button("New terminal") { createSession(provider: .claude, kind: .terminal) }
            case .advanced(let advancedItems):
                Divider()
                Menu("Advanced") {
                    ForEach(advancedItems, id: \.self) { advancedItem in
                        advancedMenuButton(advancedItem)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func advancedMenuButton(_ item: NewChatMenuAdvancedItem) -> some View {
        switch item {
        case .backgroundAgent:
            Button("New background agent…") { presentBackgroundDispatchModal() }
                .disabled(selectedProject == nil)
        case .agentView:
            Button("New Claude agent overview") { createSession(provider: .claude, kind: .agentView) }
        case .subAgentLibrary:
            Button("Show sub-agent library…") { presentSubAgentLibrary() }
        }
    }
}
