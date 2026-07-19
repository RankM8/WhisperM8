struct SettingsRouteTarget: Equatable {
    let page: SettingsPage
    let aiOutputTab: AIOutputPageTab?
    let agentChatsTab: AgentChatsSettingsPageTab?

    static func resolve(routeID: String) -> SettingsRouteTarget? {
        if let page = SettingsPage(rawValue: routeID) {
            return SettingsRouteTarget(page: page, aiOutputTab: nil, agentChatsTab: nil)
        }

        switch routeID {
        case "api":
            return SettingsRouteTarget(page: .transcription, aiOutputTab: nil, agentChatsTab: nil)
        case "codex":
            return SettingsRouteTarget(page: .aiOutput, aiOutputTab: .account, agentChatsTab: nil)
        case "modes":
            return SettingsRouteTarget(page: .aiOutput, aiOutputTab: .modes, agentChatsTab: nil)
        case "templates":
            return SettingsRouteTarget(page: .aiOutput, aiOutputTab: .templates, agentChatsTab: nil)
        case "testLab":
            return SettingsRouteTarget(page: .aiOutput, aiOutputTab: .testLab, agentChatsTab: nil)
        case "outputOverview", "history":
            return SettingsRouteTarget(page: .output, aiOutputTab: nil, agentChatsTab: nil)
        case "agentChats":
            return SettingsRouteTarget(page: .agentChats, aiOutputTab: nil, agentChatsTab: .workspace)
        case "claudeCode":
            // Historische Route auf den alten „Claude Hooks"-Tab — seit dem
            // IA-Umbau 2026-07-19 die eigene Hooks-Seite der CLAUDE-CODE-Sektion.
            return SettingsRouteTarget(page: .claudeHooks, aiOutputTab: nil, agentChatsTab: nil)
        case "hotkey", "audio":
            return SettingsRouteTarget(page: .recording, aiOutputTab: nil, agentChatsTab: nil)
        case "behavior":
            return SettingsRouteTarget(page: .general, aiOutputTab: nil, agentChatsTab: nil)
        default:
            return nil
        }
    }
}
