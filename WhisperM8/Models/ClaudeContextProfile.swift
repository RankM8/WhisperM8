import Foundation

/// App-weites, benanntes Context-Profil fuer Claude-Launches. Buendelt
/// Connector-/MCP-/Plugin-/Env-Einschraenkungen, die als session-scoped
/// `--settings`-Overlay an einen Launch gehaengt werden (siehe
/// `ClaudeContextSettingsBuilder`). Referenziert per UUID aus Projekten
/// (`AgentProject.contextProfileID`) und Sessions — die Aufloesung ist
/// lenient: ein geloeschtes Profil ergibt einfach keinen Overlay.
struct ClaudeContextProfile: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    /// Anzeigename, z. B. "Coding", "Marketing", "Voll".
    var name: String
    /// Namen der zu sperrenden claude.ai-Connectoren (z. B. "claude.ai Gmail").
    /// Serialisierung in die Settings-JSON als `[{"serverName": <name>}]`.
    var deniedMcpServers: [String]
    /// Lokale/projektbasierte MCP-Server, die deaktiviert werden sollen.
    var disabledMcpjsonServers: [String]
    /// Plugin-ID ("name@marketplace") → enabled. Nur abweichende Eintraege —
    /// nicht gelistete Plugins behalten ihren normalen Zustand.
    var enabledPlugins: [String: Bool]
    /// Zusaetzliche Env-Vars (z. B. ENABLE_CLAUDEAI_MCP_SERVERS=false,
    /// ENABLE_TOOL_SEARCH=auto). Reservierte Keys werden im Editor abgewiesen
    /// und in `ClaudeContextSettingsBuilder` defensiv gefiltert.
    var environment: [String: String]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        deniedMcpServers: [String] = [],
        disabledMcpjsonServers: [String] = [],
        enabledPlugins: [String: Bool] = [:],
        environment: [String: String] = [:],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.deniedMcpServers = deniedMcpServers
        self.disabledMcpjsonServers = disabledMcpjsonServers
        self.enabledPlugins = enabledPlugins
        self.environment = environment
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Neue Felder muessen optional dekodieren, damit aeltere Profildateien
    /// (oder von Downgrades geschriebene) nicht verworfen werden.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Profil"
        deniedMcpServers = try container.decodeIfPresent([String].self, forKey: .deniedMcpServers) ?? []
        disabledMcpjsonServers = try container.decodeIfPresent([String].self, forKey: .disabledMcpjsonServers) ?? []
        enabledPlugins = try container.decodeIfPresent([String: Bool].self, forKey: .enabledPlugins) ?? [:]
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    /// Leeres Profil → kein Settings-Fragment, kein Env-Overlay noetig.
    var isEmpty: Bool {
        deniedMcpServers.isEmpty
            && disabledMcpjsonServers.isEmpty
            && enabledPlugins.isEmpty
            && environment.isEmpty
    }

    /// Sperrt dieses Profil den Server? Connectoren stehen in
    /// `deniedMcpServers`, config-basierte Server in `disabledMcpjsonServers`.
    func blocksServer(name: String, isConnector: Bool) -> Bool {
        isConnector
            ? deniedMcpServers.contains(name)
            : disabledMcpjsonServers.contains(name)
    }
}
