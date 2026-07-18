import Foundation

/// Pure Helper-Logik, die ein `ClaudeContextProfile` in das session-scoped
/// `--settings`-Overlay uebersetzt. Claude Code merged die per `--settings`
/// uebergebene Datei additiv mit User-/Projekt-Settings und respektiert dort
/// `deniedMcpServers`, `disabledMcpjsonServers`, `enabledPlugins` und `env`.
///
/// Bewusst NICHT verwendet: `disableClaudeAiConnectors` — der Key hat
/// any-source-true-Semantik (ein `true` aus irgendeiner Quelle ist nicht
/// mehr pro Projekt rueckholbar). Connector-Steuerung laeuft ausschliesslich
/// ueber `deniedMcpServers` bzw. `ENABLE_CLAUDEAI_MCP_SERVERS`.
enum ClaudeContextSettingsBuilder {
    /// Env-Keys, die nie aus einem Profil durchgereicht werden — ein
    /// Context-Profil darf weder das Account-Config-Dir noch den GPT-Router
    /// oder API-Credentials kapern.
    static let reservedEnvironmentKeys: Set<String> = [
        "CLAUDE_CONFIG_DIR",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "CLAUDE_CODE_SUBAGENT_MODEL",
        "PATH",
        "HOME"
    ]

    /// Settings-Fragment eines Profils (ohne Hooks). Leeres Profil → `[:]`.
    static func settingsFragment(for profile: ClaudeContextProfile) -> [String: Any] {
        var fragment: [String: Any] = [:]
        if !profile.deniedMcpServers.isEmpty {
            fragment["deniedMcpServers"] = profile.deniedMcpServers.map { ["serverName": $0] }
        }
        if !profile.disabledMcpjsonServers.isEmpty {
            fragment["disabledMcpjsonServers"] = profile.disabledMcpjsonServers
        }
        if !profile.enabledPlugins.isEmpty {
            fragment["enabledPlugins"] = profile.enabledPlugins
        }
        let environment = filteredEnvironment(profile.environment)
        if !environment.isEmpty {
            fragment["env"] = environment
        }
        return fragment
    }

    /// Flacher Merge mehrerer Settings-Fragmente. Die Fragmente sind
    /// key-disjunkt ("hooks" vs. Profil-Keys); bei Kollision gewinnt das
    /// spaetere Fragment (deterministisch, kein Deep-Merge noetig).
    static func merged(_ fragments: [[String: Any]]) -> [String: Any] {
        var result: [String: Any] = [:]
        for fragment in fragments {
            result.merge(fragment) { _, new in new }
        }
        return result
    }

    /// Gefiltertes Env-Overlay fuer den PTY-Prozess — gleiche Quelle und
    /// Filterung wie das settings-`env`, damit beide Kanaele nie divergieren.
    /// (Prozess-Env wirkt ab Prozessstart; settings-`env` ist der einzige
    /// Kanal, der Daemon-gehostete `--bg`-Sessions erreicht.)
    static func processEnvironmentOverlay(for profile: ClaudeContextProfile?) -> [String: String] {
        guard let profile else { return [:] }
        return filteredEnvironment(profile.environment)
    }

    private static func filteredEnvironment(_ raw: [String: String]) -> [String: String] {
        raw.filter { !reservedEnvironmentKeys.contains($0.key) }
    }
}
