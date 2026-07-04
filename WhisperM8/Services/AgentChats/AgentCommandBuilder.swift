import Foundation

struct AgentLaunchCommand: Equatable {
    var executablePath: String
    var arguments: [String]
    var workingDirectory: String
    /// Keyboard-Shortcut-Profil fuer den Terminal-Handler. Wird vom Builder
    /// passend zur Session-Art gesetzt (Codex-Chat, Claude-Code-Chat,
    /// Claude-Agents-View). Die Agents-View-TUI nutzt eine eigene Eingabe-
    /// Implementation und braucht andere Byte-Sequenzen (z. B. CSI-u fuer
    /// Shift+Enter statt Backslash-Continuation).
    var keyboardProfile: TerminalKeyboardProfile = .claudeCodeChat
}

enum AgentCommandError: LocalizedError, Equatable {
    case commandNotFound(String)
    case missingProject(String)
    case missingExternalSessionID(String)
    case missingBackgroundShortID(String)

    var errorDescription: String? {
        switch self {
        case .commandNotFound(let command):
            return "\(command) CLI is not installed."
        case .missingProject(let path):
            return "Project folder does not exist: \(path)"
        case .missingExternalSessionID(let title):
            return "Cannot resume \(title): the original agent session ID was not indexed yet. Refresh sessions or start a new chat explicitly."
        case .missingBackgroundShortID(let title):
            return "Cannot attach to background agent \(title): no short ID stored yet. Spawn the agent first."
        }
    }
}

struct AgentCommandBuilder {
    var commandResolver: (String) -> String? = { command in
        if command == "codex" {
            return CodexStatusProbe().commandPath(command)
        }
        return Self.commandPath(command)
    }

    /// Liefert nutzerdefinierte Extra-Argumente für einen Provider (aus AppPreferences).
    /// Standard liest aus `AppPreferences.shared`, im Test überschreibbar.
    var extraArgumentsResolver: (AgentProvider) -> [String] = { provider in
        let raw: String
        switch provider {
        case .codex: raw = AppPreferences.shared.codexExtraArguments
        case .claude: raw = AppPreferences.shared.claudeExtraArguments
        }
        return Self.parseArguments(raw)
    }

    var codexServiceTierResolver: () -> CodexServiceTier = {
        CodexServiceTier.resolve(AppPreferences.shared.codexServiceTierRaw)
    }

    /// Parsed eine Whitespace-getrennte Argument-Zeile.
    /// Unterstützt einfache Quotes für Argumente mit Leerzeichen: `--text "hello world"`.
    static func parseArguments(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var result: [String] = []
        var current = ""
        var quote: Character? = nil
        for ch in trimmed {
            if let q = quote {
                if ch == q {
                    quote = nil
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch.isWhitespace {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    /// Zusaetzliche CLI-Argumente, die VOR den session-spezifischen Args
    /// eingefuegt werden — z. B. `--settings <path>` fuer die Hook-Bridge
    /// (Phase 5). `nil` wenn kein zusaetzlicher Inject gewuenscht ist.
    var extraLaunchArguments: [String] = []

    func command(for session: AgentChatSession, project: AgentProject) throws -> AgentLaunchCommand {
        guard FileManager.default.fileExists(atPath: project.path) else {
            throw AgentCommandError.missingProject(project.path)
        }

        switch session.provider {
        case .codex:
            return try codexCommand(for: session, project: project)
        case .claude:
            return try claudeCommand(for: session, project: project)
        }
    }

    private func codexCommand(for session: AgentChatSession, project: AgentProject) throws -> AgentLaunchCommand {
        guard let executable = commandResolver("codex") else {
            throw AgentCommandError.commandNotFound("Codex")
        }

        let extra = extraArgumentsResolver(.codex)
        let serviceTierArguments = codexServiceTierResolver().configArguments
        // Subagent-Jobs hängen am Parent-PROJEKT, arbeiten aber ggf. in
        // einem eigenen cwd (Worktree) — Resume/Übernahme muss dort laufen.
        let workingDirectory = session.subagentCwd ?? project.path

        if session.hasLaunchedInitialPrompt {
            guard let externalSessionID = session.externalSessionID else {
                throw AgentCommandError.missingExternalSessionID(session.title)
            }
            var arguments: [String] = ["resume"]
            arguments.append(contentsOf: extra)
            arguments.append(contentsOf: [
                "-C", workingDirectory,
                "-m", session.model,
                "-c", "model_reasoning_effort=\(session.reasoningEffort)",
            ])
            arguments.append(contentsOf: serviceTierArguments)
            arguments.append(contentsOf: [
                externalSessionID
            ])
            return AgentLaunchCommand(
                executablePath: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                keyboardProfile: .codexChat
            )
        }

        var arguments: [String] = []
        arguments.append(contentsOf: extra)
        arguments.append(contentsOf: [
            "-C", project.path,
            "-m", session.model,
            "-c", "model_reasoning_effort=\(session.reasoningEffort)"
        ])
        arguments.append(contentsOf: serviceTierArguments)
        for imagePath in session.imagePaths {
            arguments.append(contentsOf: ["--image", imagePath])
        }
        if let initialPrompt = session.initialPrompt, !initialPrompt.isEmpty {
            arguments.append(initialPrompt)
        }

        return AgentLaunchCommand(
            executablePath: executable,
            arguments: arguments,
            workingDirectory: project.path,
            keyboardProfile: .codexChat
        )
    }

    private func claudeCommand(for session: AgentChatSession, project: AgentProject) throws -> AgentLaunchCommand {
        guard let executable = commandResolver("claude") else {
            throw AgentCommandError.commandNotFound("Claude")
        }

        // Claude Agents View ist ein separater Subcommand (`claude agents`)
        // mit eigener TUI fuer Background-Sessions. Kein --resume,
        // kein --session-id, keine Hook-Bridge — das ist ein
        // Dashboard, kein Chat.
        if session.isAgentView {
            var arguments: [String] = ["agents"]
            // User-defined claude-Args koennen z. B. `--setting-sources` setzen.
            arguments.append(contentsOf: extraArgumentsResolver(.claude))
            return AgentLaunchCommand(
                executablePath: executable,
                arguments: arguments,
                workingDirectory: project.path,
                keyboardProfile: .claudeAgentsView
            )
        }

        // Background-Agent: vom Claude-Supervisor-Daemon gehostet, von uns
        // per `claude --bg "<prompt>"` gespawnt (separater Process, siehe
        // `BackgroundAgentSpawner`) und hier per `claude attach <short-id>`
        // in den PTY-Tab geklemmt. Voraussetzung: die Short-ID ist
        // bekannt — den Spawn-Pfad bauen wir nicht hier, weil er kein
        // PTY ist.
        if session.isBackgroundChat {
            guard let shortID = session.backgroundShortID, !shortID.isEmpty else {
                throw AgentCommandError.missingBackgroundShortID(session.title)
            }
            var arguments: [String] = ["attach"]
            // User-defined extras zuerst, falls jemand z. B. `--verbose` will.
            arguments.append(contentsOf: extraArgumentsResolver(.claude))
            arguments.append(shortID)
            return AgentLaunchCommand(
                executablePath: executable,
                arguments: arguments,
                workingDirectory: project.path,
                // Attach landet in einer normalen Claude-Chat-Session, also
                // selbes Keyboard-Profil wie ein interaktiver `.chat`.
                keyboardProfile: .claudeCodeChat
            )
        }

        var arguments: [String] = []
        // Vom Caller injizierte Args (z. B. `--settings <hook-settings.json>`)
        // kommen ganz vorne, damit Claude sie sicher beim Parse sieht.
        arguments.append(contentsOf: extraLaunchArguments)
        // User-defined extras (z. B. --dangerously-skip-permissions) zuerst,
        // damit sie auch beim Resume durchgehen.
        arguments.append(contentsOf: extraArgumentsResolver(.claude))

        if let forkSource = session.forkSourceSessionID, !forkSource.isEmpty,
           (session.externalSessionID?.isEmpty ?? true) {
            // Fork: vom Stand der Quell-Session resumen, aber in eine NEUE
            // Session-ID abzweigen (Original bleibt unangetastet). Greift nur
            // solange die eigene ID noch nicht gebunden ist — sobald der
            // SessionStart-Hook `externalSessionID` gesetzt hat, läuft der
            // Resume über die neue Fork-ID (Pfad unten).
            arguments.append(contentsOf: ["--resume", forkSource, "--fork-session"])
        } else if session.hasLaunchedInitialPrompt,
                  let externalSessionID = session.externalSessionID,
                  !externalSessionID.isEmpty {
            // Resume NUR mit einer real von Claude vergebenen, gebundenen ID.
            arguments.append(contentsOf: ["--resume", externalSessionID])
        }
        // Sonst: frischer Start OHNE `--session-id`. Claude vergibt die Session-
        // ID selbst; SessionStart-Hook + Indexer-Merge binden die REALE, von
        // Claude geschriebene ID nach (Weg B / Superset-Prinzip). Ein erzwungenes
        // `--session-id` war die Wurzel der „No conversation found"-Fehler —
        // Claude persistierte nicht zuverlässig unter der vorgegebenen ID, und
        // beim Resume zeigte die ID dann ins Leere.

        if !session.hasLaunchedInitialPrompt,
           let initialPrompt = session.initialPrompt,
           !initialPrompt.isEmpty {
            arguments.append(initialPrompt)
        }

        return AgentLaunchCommand(
            executablePath: executable,
            arguments: arguments,
            workingDirectory: project.path,
            keyboardProfile: .claudeCodeChat
        )
    }

    /// Baut die Argv fuer einen `claude --bg`-Spawn-Subprocess. Wird vom
    /// `BackgroundAgentSpawner` benutzt — der Spawn selbst ist *kein*
    /// PTY-Launch, sondern ein einmaliger Subprocess der die Short-ID
    /// auf stdout druckt und dann beendet. Wir bauen die Args trotzdem
    /// hier zentral, damit Spawn und Attach in derselben Code-Linie liegen.
    ///
    /// Reihenfolge: `--settings` muss vor `--bg` stehen, damit Claude die
    /// Hook-Konfiguration vor dem Session-Setup einliest. `--agent` und
    /// `--permission-mode` sind optionale Flags vor dem Prompt.
    static func backgroundSpawnArguments(
        initialPrompt: String,
        settingsFilePath: String? = nil,
        subAgent: String? = nil,
        permissionMode: String? = nil,
        extraArguments: [String] = []
    ) -> [String] {
        var args: [String] = []
        if let path = settingsFilePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            args.append(contentsOf: ["--settings", path])
        }
        args.append("--bg")
        if let agent = subAgent?.trimmingCharacters(in: .whitespacesAndNewlines), !agent.isEmpty {
            args.append(contentsOf: ["--agent", agent])
        }
        if let mode = permissionMode?.trimmingCharacters(in: .whitespacesAndNewlines), !mode.isEmpty {
            args.append(contentsOf: ["--permission-mode", mode])
        }
        args.append(contentsOf: extraArguments)
        args.append(initialPrompt)
        return args
    }

    static func commandPath(_ command: String) -> String? {
        if let cached = AgentCommandPathCache.shared.path(for: command) {
            return cached
        }

        let startedAt = Date()
        if let path = which(command) {
            AgentCommandPathCache.shared.store(path, for: command)
            Logger.agentPerformance.debug("agent_command_resolve command=\(command, privacy: .public) source=which durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
            return path
        }

        // `~/.local/bin` = nativer Claude-Code-Installer, `~/.claude/local` =
        // Alias-Ziel von `claude install` (migrate-installer). Beide liegen
        // außerhalb der Brew-/System-Pfade und fehlen im launchd-PATH.
        let fallbackDirectories = [
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.claude/local",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        for directory in fallbackDirectories {
            let path = "\(directory)/\(command)"
            if FileManager.default.isExecutableFile(atPath: path) {
                AgentCommandPathCache.shared.store(path, for: command)
                Logger.agentPerformance.debug("agent_command_resolve command=\(command, privacy: .public) source=fallback durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
                return path
            }
        }

        Logger.agentPerformance.debug("agent_command_resolve command=\(command, privacy: .public) source=missing durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
        return nil
    }

    private static func which(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        // Ohne korrigiertes Env sucht `which` nur im minimalen launchd-PATH
        // der GUI-App und findet user-installierte CLIs (claude unter
        // ~/.local/bin, mise-shims, ...) nicht.
        process.environment = LoginShellEnvironment.shared.processEnvironment()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path?.isEmpty == false ? path : nil
        } catch {
            return nil
        }
    }
}

private final class AgentCommandPathCache {
    static let shared = AgentCommandPathCache()

    private let lock = NSLock()
    private var paths: [String: String] = [:]

    func path(for command: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return paths[command]
    }

    func store(_ path: String, for command: String) {
        lock.lock()
        paths[command] = path
        lock.unlock()
    }
}
