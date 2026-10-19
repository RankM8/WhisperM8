import Foundation

/// „Advanced agent features" (LR-AU-031): Entwickler-nahe Chat-Funktionen
/// (Hintergrund-Agent, Claude Agent View, Sub-Agent-Bibliothek, Terminal)
/// stehen nur im „+"-Menü, wenn der Schalter an ist. Neuinstallationen starten
/// mit AUS, Bestandsnutzer (Workspace-Datei mit Sessions) mit AN — so geht
/// keinem etwas verloren, und neue Nutzer sehen zuerst nur Claude und Codex.
enum AgentAdvancedFeatures {
    /// Pur: Startwert aus dem Vorhandensein von Sessions.
    static func initialValue(workspaceHasSessions: Bool) -> Bool {
        workspaceHasSessions
    }

    /// Einmalig beim Start: bestimmt den Wert nur, wenn noch keine Entscheidung
    /// gespeichert ist. `workspaceHasSessions` wird dann (und nur dann)
    /// ausgewertet — der Lesezugriff auf die Workspace-Datei bleibt auf den
    /// ersten Start mit diesem Stand beschränkt.
    @discardableResult
    static func resolveAtLaunch(
        preferences: AppPreferences = .shared,
        workspaceHasSessions: () -> Bool
    ) -> Bool {
        guard !preferences.hasAgentAdvancedFeaturesDecision else {
            return preferences.agentAdvancedFeaturesEnabled
        }
        let value = initialValue(workspaceHasSessions: workspaceHasSessions())
        preferences.agentAdvancedFeaturesEnabled = value
        return value
    }

    /// Produktiver Aufruf: schaut in die Workspace-Datei.
    static func resolveAtLaunch() {
        resolveAtLaunch { !AgentWorkspaceRepository(fileURL: nil).loadReadOnly().sessions.isEmpty }
    }
}

/// Einträge des „+"-Menüs für neue Chats (pur, für beide Schalterzustände getestet).
enum NewChatMenuItem: Equatable {
    case claudeChat
    case codexChat
    case gptChat
    /// Untermenü „Advanced" mit den erweiterten Einträgen.
    case advanced([NewChatMenuAdvancedItem])
}

enum NewChatMenuAdvancedItem: Equatable {
    case terminal
    case backgroundAgent
    case agentView
    case subAgentLibrary
}

enum NewChatMenuPlan {
    /// Claude vor Codex; GPT-Chat nur mit aktivem GPT-Backend (eigener Opt-in);
    /// die erweiterten Einträge nur bei eingeschaltetem Schalter.
    static func items(advancedEnabled: Bool, gptBackendEnabled: Bool) -> [NewChatMenuItem] {
        var items: [NewChatMenuItem] = [.claudeChat, .codexChat]
        if gptBackendEnabled { items.append(.gptChat) }
        if advancedEnabled {
            items.append(.advanced([.terminal, .backgroundAgent, .agentView, .subAgentLibrary]))
        }
        return items
    }
}
