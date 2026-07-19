import Foundation

/// Herkunft eines MCP-Servers — bestimmt Badge und welches Profil-Feld ihn
/// sperren kann (`deniedMcpServers` fuer Connectoren, `disabledMcpjsonServers`
/// fuer config-basierte Server).
enum ClaudeMCPServerOrigin: String, CaseIterable {
    /// claude.ai-Account-Connector (injiziert, nicht lokal konfiguriert).
    case connector
    /// User-Scope (`.claude.json` des Config-Dirs).
    case user
    /// Projekt-Scope (`.mcp.json` bzw. `projects.*.mcpServers`).
    case project
    /// Von einem installierten Plugin mitgebracht.
    case plugin

    var badgeLabel: String {
        switch self {
        case .connector: return "claude.ai"
        case .user: return "user"
        case .project: return "project"
        case .plugin: return "plugin"
        }
    }
}

struct ClaudeMCPServerEntry: Equatable, Identifiable {
    var name: String
    var origin: ClaudeMCPServerOrigin
    /// URL bzw. Command des Servers (Anzeige).
    var detail: String
    /// Health-Status aus `claude mcp list` ("✔ Connected", "! Needs
    /// authentication", "⏸ Pending approval …") — nil, wenn der Server nur
    /// aus einer Config bekannt ist.
    var status: String?
    /// Projekt-Pfad bei `.project`-Herkunft.
    var projectPath: String?
    /// Plugin-ID bei `.plugin`-Herkunft.
    var pluginID: String?

    var id: String { "\(origin.rawValue)|\(projectPath ?? pluginID ?? "")|\(name)" }

    /// Profil-Feld, das diesen Server sperrt: Connectoren via
    /// `deniedMcpServers`, alles config-basierte via `disabledMcpjsonServers`.
    var isDeniableConnector: Bool { origin == .connector }
}

/// Inventar aller MCP-Server aus vier Quellen: `claude mcp list`
/// (Health-Status, Connectoren), `.claude.json` (user + projects),
/// `.mcp.json` der bekannten Projekte und Plugin-MCPs. Pure Parser +
/// injizierbare Loader (Muster `CodexGlobalConfigReader`); der CLI-Aufruf
/// laeuft ueber `ClaudePluginCLI` (Serializer + Profil-Env inklusive).
struct ClaudeMCPInventory {
    var cli = ClaudePluginCLI()
    /// `.claude.json` des Ziel-Account-Profils. main → `~/.claude.json`,
    /// Profil → `~/.claude-profiles/<name>/.claude.json`.
    var configJSONLoader: (String?) -> Data? = { profileName in
        let base: URL
        if let profileName, profileName != ClaudeAccountProfiles.mainProfileName {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude-profiles/\(profileName)/.claude.json")
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude.json")
        }
        return try? Data(contentsOf: base)
    }
    /// `.mcp.json` eines Projekts (Repo-Root).
    var projectMCPJSONLoader: (String) -> Data? = { projectPath in
        try? Data(contentsOf: URL(fileURLWithPath: projectPath).appendingPathComponent(".mcp.json"))
    }
    /// Bekannte Projekt-Pfade (Agent-Chats-Workspace).
    var knownProjectPaths: () -> [String] = {
        AgentSessionStore().loadWorkspace().projects.map(\.path)
    }

    // MARK: - Sammeln (IO)

    /// Volles Inventar. `pluginList` optional hereinreichen, wenn der Caller
    /// (Plugin-Manager-Model) sie schon geladen hat — spart einen CLI-Call.
    /// Der `claude mcp list`-Aufruf macht Health-Checks und kann mehrere
    /// Sekunden dauern; Caller sollten cachen.
    func collect(
        accountProfile: String?,
        pluginList: ClaudePluginList?
    ) async -> [ClaudeMCPServerEntry] {
        let cliServers: [ParsedCLIServer]
        do {
            let output = try await cli.mcpList(accountProfile: accountProfile)
            cliServers = Self.parseMCPListOutput(output)
        } catch {
            Logger.agentStore.warning("mcp_list_failed error=\(error.localizedDescription, privacy: .public)")
            cliServers = []
        }

        let config = Self.parseConfigJSON(configJSONLoader(accountProfile))
        let projectServers = knownProjectPaths().flatMap { path in
            Self.parseMCPJSON(projectMCPJSONLoader(path)).map { (path: path, name: $0.name, detail: $0.detail) }
        }
        let pluginServers = (pluginList?.installed ?? []).flatMap { plugin in
            (plugin.mcpServers ?? [:]).map { (pluginID: plugin.id, name: $0.key, detail: $0.value.url ?? $0.value.type ?? "") }
        }

        return Self.merge(
            cliServers: cliServers,
            userServers: config.userServers,
            configProjectServers: config.projectServers,
            mcpJSONProjectServers: projectServers,
            pluginServers: pluginServers
        )
    }

    // MARK: - Pure Parser

    struct ParsedCLIServer: Equatable {
        var name: String
        var detail: String
        var status: String?
    }

    /// Parst den Text von `claude mcp list` (kein --json, verifiziert
    /// 2026-07-19). Zeilenformat: `<name>: <url/command> - <status>`;
    /// Kopf-/Leerzeilen werden uebersprungen. Degradierend — unbekannte
    /// Zeilen fallen einfach raus.
    static func parseMCPListOutput(_ stdout: String) -> [ParsedCLIServer] {
        var result: [ParsedCLIServer] = []
        for rawLine in stdout.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  !line.hasPrefix("Checking MCP server health"),
                  let separator = line.range(of: ": ") else { continue }
            let name = String(line[..<separator.lowerBound])
            let rest = String(line[separator.upperBound...])
            if let statusSeparator = rest.range(of: " - ", options: .backwards) {
                result.append(ParsedCLIServer(
                    name: name,
                    detail: String(rest[..<statusSeparator.lowerBound]),
                    status: String(rest[statusSeparator.upperBound...])
                ))
            } else {
                result.append(ParsedCLIServer(name: name, detail: rest, status: nil))
            }
        }
        return result
    }

    struct ParsedConfig: Equatable {
        var userServers: [(name: String, detail: String)]
        var projectServers: [(path: String, name: String, detail: String)]

        static func == (lhs: ParsedConfig, rhs: ParsedConfig) -> Bool {
            lhs.userServers.elementsEqual(rhs.userServers, by: ==)
                && lhs.projectServers.elementsEqual(rhs.projectServers, by: ==)
        }
    }

    /// Liest `mcpServers` (top-level = user) und `projects.<path>.mcpServers`
    /// aus einer `.claude.json`. Defensiv: alles optional.
    static func parseConfigJSON(_ data: Data?) -> ParsedConfig {
        var config = ParsedConfig(userServers: [], projectServers: [])
        guard let data,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return config
        }
        if let servers = root["mcpServers"] as? [String: Any] {
            config.userServers = servers
                .map { (name: $0.key, detail: Self.serverDetail($0.value)) }
                .sorted { $0.name < $1.name }
        }
        if let projects = root["projects"] as? [String: Any] {
            for (path, value) in projects {
                guard let project = value as? [String: Any],
                      let servers = project["mcpServers"] as? [String: Any],
                      !servers.isEmpty else { continue }
                for (name, server) in servers {
                    config.projectServers.append((path: path, name: name, detail: Self.serverDetail(server)))
                }
            }
            config.projectServers.sort { ($0.path, $0.name) < ($1.path, $1.name) }
        }
        return config
    }

    /// Liest die Server-Namen einer `.mcp.json` (Projekt-Root).
    static func parseMCPJSON(_ data: Data?) -> [(name: String, detail: String)] {
        guard let data,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else {
            return []
        }
        return servers
            .map { (name: $0.key, detail: Self.serverDetail($0.value)) }
            .sorted { $0.name < $1.name }
    }

    private static func serverDetail(_ value: Any) -> String {
        guard let dict = value as? [String: Any] else { return "" }
        if let url = dict["url"] as? String { return url }
        if let command = dict["command"] as? String {
            let args = (dict["args"] as? [String]) ?? []
            return ([command] + args).joined(separator: " ")
        }
        return (dict["type"] as? String) ?? ""
    }

    /// Fuehrt alle Quellen zusammen. CLI-Zeilen liefern Status + Connectoren;
    /// Config-/Plugin-Quellen liefern die Herkunft. Klassifikation der
    /// CLI-Zeilen: `claude.ai `-Praefix → Connector, `plugin:`-Praefix →
    /// Plugin, sonst per Namensabgleich mit den Configs (Fallback: user).
    static func merge(
        cliServers: [ParsedCLIServer],
        userServers: [(name: String, detail: String)],
        configProjectServers: [(path: String, name: String, detail: String)],
        mcpJSONProjectServers: [(path: String, name: String, detail: String)],
        pluginServers: [(pluginID: String, name: String, detail: String)]
    ) -> [ClaudeMCPServerEntry] {
        var entries: [ClaudeMCPServerEntry] = []
        var statusByName: [String: ParsedCLIServer] = [:]
        for server in cliServers { statusByName[server.name] = server }

        func status(for name: String) -> String? { statusByName[name]?.status }

        // 1) Config-Quellen (Herkunft ist hier sicher).
        for server in userServers {
            entries.append(ClaudeMCPServerEntry(
                name: server.name, origin: .user, detail: server.detail,
                status: status(for: server.name)
            ))
        }
        for server in configProjectServers + mcpJSONProjectServers {
            // .mcp.json und projects-Sektion koennen denselben Server nennen.
            if entries.contains(where: { $0.origin == .project && $0.name == server.name && $0.projectPath == server.path }) {
                continue
            }
            entries.append(ClaudeMCPServerEntry(
                name: server.name, origin: .project, detail: server.detail,
                status: status(for: server.name), projectPath: server.path
            ))
        }
        for server in pluginServers {
            // CLI-Zeilenname: plugin:<pluginName>:<serverName>.
            let pluginName = server.pluginID.split(separator: "@").first.map(String.init) ?? server.pluginID
            entries.append(ClaudeMCPServerEntry(
                name: server.name, origin: .plugin, detail: server.detail,
                status: status(for: "plugin:\(pluginName):\(server.name)"),
                pluginID: server.pluginID
            ))
        }

        // 2) CLI-only-Zeilen: Connectoren + alles, was keine Config kennt.
        let knownNames = Set(entries.map(\.name))
        for server in cliServers {
            if server.name.hasPrefix("claude.ai ") {
                entries.append(ClaudeMCPServerEntry(
                    name: server.name, origin: .connector,
                    detail: server.detail, status: server.status
                ))
            } else if server.name.hasPrefix("plugin:") {
                // Bereits ueber die Plugin-Liste abgedeckt; ohne Plugin-Liste
                // trotzdem anzeigen (Name-Teil hinter dem letzten Doppelpunkt).
                let shortName = server.name.split(separator: ":").last.map(String.init) ?? server.name
                if !entries.contains(where: { $0.origin == .plugin && $0.name == shortName }) {
                    entries.append(ClaudeMCPServerEntry(
                        name: shortName, origin: .plugin,
                        detail: server.detail, status: server.status,
                        pluginID: server.name
                    ))
                }
            } else if !knownNames.contains(server.name) {
                entries.append(ClaudeMCPServerEntry(
                    name: server.name, origin: .user,
                    detail: server.detail, status: server.status
                ))
            }
        }

        return entries.sorted {
            ($0.origin.rawValue, $0.name.lowercased()) < ($1.origin.rawValue, $1.name.lowercased())
        }
    }
}
