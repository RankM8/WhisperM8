import Foundation

/// Headless-Wrapper um das `claude plugin`-CLI (Muster
/// `BackgroundAgentLifecycle`: enum-getriebene Subcommands, injizierbare
/// Seams fuer Tests). WhisperM8 schreibt selbst NIE unter `~/.claude/` —
/// alle Mutationen laufen ueber das offizielle CLI.
///
/// Profil-Bewusstsein: Plugins leben pro CLAUDE_CONFIG_DIR. Jeder Aufruf
/// baut sein Env explizit — `LoginShellEnvironment` (strippt geerbtes
/// CLAUDE_CONFIG_DIR) + `ClaudeAccountProfiles.environmentOverrides` fuer
/// das Ziel-Profil. Achtung: App-erstellte Profile teilen `plugins/` per
/// Symlink mit `main` (siehe `ClaudeAccountProfiles.sharedItems`) —
/// Aenderungen wirken dann account-uebergreifend.
/// Prozessweite FIFO-Serialisierung aller `claude plugin`-Aufrufe. Claudes
/// Config-Dateien sind nicht lock-geschuetzt, und Model-Instanzen gibt es
/// mehrfach (Plugin-Page, Context-Profile-Tab, mehrere Fenster) — die
/// `isBusy`-Sperre der Models ist deshalb nur UI-Zucker; die harte Garantie
/// "nie zwei claude-plugin-Prozesse parallel" liegt HIER, in der CLI-Schicht
/// (Review-Befund 2026-07-19).
actor ClaudePluginCLISerializer {
    static let shared = ClaudePluginCLISerializer()
    private var tail: Task<Void, Never> = Task {}

    func run<T: Sendable>(_ operation: @escaping () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { () -> T in
            await previous.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}

struct ClaudePluginCLI {
    enum Scope: String, CaseIterable, Identifiable {
        case user
        case project
        case local

        var id: String { rawValue }
    }

    /// Test-Seams (Muster `commandResolver`/`processRunner` im Spawner).
    var commandResolver: (String) -> String? = { AgentCommandBuilder.commandPath($0) }
    var environmentBuilder: (String?) -> [String: String] = { profileName in
        var environment = LoginShellEnvironment.shared.processEnvironment()
        environment.merge(
            ClaudeAccountProfiles().environmentOverrides(forProfile: profileName)
        ) { _, profile in profile }
        environment["NO_COLOR"] = "1"
        environment["CLICOLOR"] = "0"
        return environment
    }
    /// Der eigentliche Prozess-Runner — default `AgentHeadlessCLI`.
    /// `marketplace update` und `list --available` koennen Netz brauchen.
    var runner: (URL, [String], [String: String]) async throws -> String = { executable, arguments, environment in
        try await AgentHeadlessCLI(timeout: 120).run(
            executable: executable,
            arguments: arguments,
            environment: environment
        )
    }

    enum CLIError: Error, LocalizedError {
        case claudeNotFound

        var errorDescription: String? {
            switch self {
            case .claudeNotFound:
                return "Claude CLI wurde nicht gefunden."
            }
        }
    }

    // MARK: - Plugins

    /// Installierte + verfuegbare Plugins in einem Aufruf.
    func listPlugins(accountProfile: String?) async throws -> ClaudePluginList {
        let output = try await run(["plugin", "list", "--available", "--json"], accountProfile: accountProfile)
        return try ClaudePluginListParser.parse(Data(output.utf8))
    }

    /// Details inkl. projizierter Token-Kosten (Text-Output, degradierender
    /// Parser — fehlende Werte sind Anzeige-Luecken, kein Fehler).
    func details(pluginName: String, accountProfile: String?) async throws -> ClaudePluginDetails {
        let output = try await run(["plugin", "details", pluginName], accountProfile: accountProfile)
        return ClaudePluginDetailsParser.parse(output)
    }

    func install(
        _ pluginID: String,
        scope: Scope,
        config: [String: String] = [:],
        accountProfile: String?
    ) async throws {
        var arguments = ["plugin", "install", pluginID, "--scope", scope.rawValue]
        for (key, value) in config.sorted(by: { $0.key < $1.key }) {
            arguments.append(contentsOf: ["--config", "\(key)=\(value)"])
        }
        _ = try await run(arguments, accountProfile: accountProfile)
    }

    func uninstall(_ pluginID: String, scope: Scope?, accountProfile: String?) async throws {
        var arguments = ["plugin", "uninstall", pluginID]
        if let scope {
            arguments.append(contentsOf: ["--scope", scope.rawValue])
        }
        _ = try await run(arguments, accountProfile: accountProfile)
    }

    func update(_ pluginID: String, accountProfile: String?) async throws {
        _ = try await run(["plugin", "update", pluginID], accountProfile: accountProfile)
    }

    func setEnabled(
        _ enabled: Bool,
        pluginID: String,
        scope: Scope?,
        accountProfile: String?
    ) async throws {
        var arguments = ["plugin", enabled ? "enable" : "disable", pluginID]
        if let scope {
            arguments.append(contentsOf: ["--scope", scope.rawValue])
        }
        _ = try await run(arguments, accountProfile: accountProfile)
    }

    /// Entfernt verwaiste Auto-Dependencies; gibt den Roh-Output zurueck
    /// (die UI zeigt ihn als Ergebnis-Text).
    @discardableResult
    func prune(accountProfile: String?) async throws -> String {
        try await run(["plugin", "prune"], accountProfile: accountProfile)
    }

    // MARK: - MCP

    /// `claude mcp list` — Text-Output (kein --json, verifiziert 2026-07-19)
    /// mit Health-Checks; kann mehrere Sekunden dauern. Parsing macht
    /// `ClaudeMCPInventory.parseMCPListOutput`.
    func mcpList(accountProfile: String?) async throws -> String {
        try await run(["mcp", "list"], accountProfile: accountProfile)
    }

    // MARK: - Marketplaces

    func marketplaces(accountProfile: String?) async throws -> [ClaudeMarketplace] {
        let output = try await run(["plugin", "marketplace", "list", "--json"], accountProfile: accountProfile)
        return try ClaudePluginListParser.parseMarketplaces(Data(output.utf8))
    }

    func addMarketplace(source: String, accountProfile: String?) async throws {
        _ = try await run(["plugin", "marketplace", "add", source], accountProfile: accountProfile)
    }

    func removeMarketplace(name: String, accountProfile: String?) async throws {
        _ = try await run(["plugin", "marketplace", "remove", name], accountProfile: accountProfile)
    }

    /// `name == nil` aktualisiert alle Marketplaces.
    func updateMarketplaces(name: String?, accountProfile: String?) async throws {
        var arguments = ["plugin", "marketplace", "update"]
        if let name {
            arguments.append(name)
        }
        _ = try await run(arguments, accountProfile: accountProfile)
    }

    // MARK: - Internals

    private func run(_ arguments: [String], accountProfile: String?) async throws -> String {
        guard let executablePath = commandResolver("claude") else {
            throw CLIError.claudeNotFound
        }
        let runner = self.runner
        let environment = environmentBuilder(accountProfile)
        return try await ClaudePluginCLISerializer.shared.run {
            try await runner(
                URL(fileURLWithPath: executablePath),
                arguments,
                environment
            )
        }
    }
}
