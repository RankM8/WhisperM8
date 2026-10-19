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

    /// Produktiver Aufruf: schaut in die Workspace-Datei — ohne sie zu dekodieren
    /// (sie kann mehrere MB groß sein, der Aufruf läuft im Start auf dem Main Thread).
    static func resolveAtLaunch() {
        resolveAtLaunch {
            let url = AgentWorkspaceRepository.defaultFileURL()
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return false }
            return workspaceHasSessions(in: data)
        }
    }

    /// Pur: enthält das JSON ein nicht-leeres `"sessions"`-Array? Sucht den Schlüssel
    /// in den Bytes und schaut nur auf das erste Zeichen nach `[` — kein Parsen.
    static func workspaceHasSessions(in data: Data) -> Bool {
        let key = Data("\"sessions\"".utf8)
        guard let range = data.range(of: key) else { return false }
        var index = range.upperBound
        func next() -> UInt8? {
            while index < data.endIndex {
                defer { index = data.index(after: index) }
                let byte = data[index]
                if byte != 0x20, byte != 0x0A, byte != 0x0D, byte != 0x09 { return byte }
            }
            return nil
        }
        guard next() == UInt8(ascii: ":"), next() == UInt8(ascii: "[") else { return false }
        guard let first = next() else { return false }
        return first != UInt8(ascii: "]")
    }
}

/// Einträge des „+"-Menüs für neue Chats (pur, für beide Schalterzustände getestet).
enum NewChatMenuItem: Equatable {
    case claudeChat
    case codexChat
    case gptChat
    /// Normale Login-Shell — wie bisher auf oberster Ebene, aber nur mit dem Schalter.
    case terminal
    /// Untermenü „Advanced" mit den erweiterten Einträgen.
    case advanced([NewChatMenuAdvancedItem])
}

enum NewChatMenuAdvancedItem: Equatable {
    case backgroundAgent
    case agentView
    case subAgentLibrary
}

enum NewChatMenuPlan {
    /// Claude vor Codex; GPT-Chat nur mit aktivem GPT-Backend (eigener Opt-in);
    /// Terminal und das Untermenü „Advanced" nur bei eingeschaltetem Schalter.
    static func items(advancedEnabled: Bool, gptBackendEnabled: Bool) -> [NewChatMenuItem] {
        var items: [NewChatMenuItem] = [.claudeChat, .codexChat]
        if gptBackendEnabled { items.append(.gptChat) }
        if advancedEnabled {
            items.append(.terminal)
            items.append(.advanced([.backgroundAgent, .agentView, .subAgentLibrary]))
        }
        return items
    }
}
