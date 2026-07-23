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
    /// Zusaetzliche Env-Variablen fuer den Launch, gemerged ueber das
    /// LoginShellEnvironment (z. B. `CLAUDE_CONFIG_DIR` fuer Account-Profile).
    var environmentOverrides: [String: String] = [:]
    /// Keys, die auch aus dem geerbten Login-/App-Environment entfernt werden
    /// muessen. Attach nutzt dies, um keine fremden GPT-Kapazitaetswerte zu erben.
    var environmentRemovals: Set<String> = []
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

    /// Liefert die Env-Overrides fuer das Claude-Account-Profil einer Session
    /// (`CLAUDE_CONFIG_DIR`). Default liest die echten Profile von der Platte,
    /// im Test ueberschreibbar. `nil`/main → leeres Dict.
    var claudeProfileEnvironmentResolver: (String?) -> [String: String] = { profileName in
        ClaudeAccountProfiles().environmentOverrides(forProfile: profileName)
    }

    var gptBackendEnabledResolver: () -> Bool = {
        AppPreferences.shared.claudeGPTBackendEnabled
    }

    var gptFastModeEnabledResolver: () -> Bool = {
        AppPreferences.shared.claudeGPTFastModeEnabled
    }

    var gptRouterPortResolver: () -> Int = {
        AppPreferences.shared.claudeGPTRouterPort
    }

    var gptSubagentModelResolver: () -> String = {
        AppPreferences.shared.claudeGPTSubagentModel
    }

    /// Konfiguriertes GPT-Standardmodell (leer = keins). Dient bei
    /// automatischer Picker-Belegung als Fallback vor dem kanonischen Modell.
    var gptDefaultModelResolver: () -> String = {
        AppPreferences.shared.claudeGPTBackendDefaultModel
    }

    /// Explizites Modell fuer den einen Custom-Eintrag im `/model`-Picker.
    /// Leer behaelt die automatische Ableitung aus Standard-/Canonical-Modell.
    var gptPickerModelResolver: () -> String = {
        AppPreferences.shared.claudeGPTPickerModel
    }

    /// Gewähltes GPT-Kontextprofil. Bis 272k gilt es für die gemeinsame
    /// Allowlist; das experimentelle 372k-Profil lässt per Modellguard nur Sol
    /// zu und kompaktifiziert durch Claude Codes interne Reserve um 339k.
    /// Der prozessweite Auto-Compact-Deckel bleibt davon getrennt bei 1M, damit
    /// native 1M-Modelle in derselben Mischsession nicht begrenzt werden.
    var gptContextWindowResolver: () -> Int = {
        AppPreferences.shared.claudeGPTContextWindow
    }

    static let routerAutoCompactCeiling = 1_000_000
    static let gptContextEnvironmentKeys = [
        "CLAUDE_CODE_MAX_CONTEXT_TOKENS",
        "CLAUDE_CODE_AUTO_COMPACT_WINDOW",
        "WHISPERM8_GPT56_CONTEXT_WINDOW",
    ]

    /// Lokalisiert das Claude-Transcript einer Session ueber ALLE Account-
    /// Roots (main + Profile) — (externalSessionID, cwd) → JSONL-URL.
    /// Default: echter Datei-Lookup, im Test ueberschreibbar.
    var claudeTranscriptLocator: (String, String) -> URL? = { externalSessionID, cwd in
        AgentTranscriptLocator.locate(provider: .claude, externalSessionID: externalSessionID, cwd: cwd)
    }

    /// Liefert die Login-Shell des Users für `.terminal`-Sessions.
    /// Default liest `$SHELL` (von launchd auch für GUI-Apps gesetzt) und
    /// fällt auf `/bin/zsh` zurück, wenn die Variable fehlt oder auf kein
    /// ausführbares Binary zeigt. Im Test überschreibbar.
    var shellResolver: () -> String = {
        Self.resolveLoginShell(
            fromEnvironment: ProcessInfo.processInfo.environment["SHELL"],
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }

    /// Pure Auflösung der Login-Shell — separat, damit sie ohne echtes
    /// Filesystem testbar ist.
    static func resolveLoginShell(
        fromEnvironment shellValue: String?,
        isExecutable: (String) -> Bool
    ) -> String {
        let trimmed = shellValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, trimmed.hasPrefix("/"), isExecutable(trimmed) {
            return trimmed
        }
        return "/bin/zsh"
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

    static func argumentsContainResumeFlag(_ arguments: [String]) -> Bool {
        arguments.contains { argument in
            switch argument {
            case "-c", "--continue", "-r", "--resume":
                return true
            default:
                return argument.hasPrefix("--resume=")
            }
        }
    }

    func normalizedGPTContextWindow() -> Int {
        AppPreferences.normalizedClaudeGPTContextWindow(
            gptContextWindowResolver()
        )
    }

    /// Router-Kern-Env fuer jede direkt von WhisperM8 gestartete Claude-CLI bei
    /// aktivem GPT-Backend. Background-Launches geben denselben Snapshot sowohl
    /// an den `--bg`-Dispatcher als auch tief gemergt in die session-scoped
    /// Settings-Datei fuer den Supervisor-Worker. Der Attach-Pfad entfernt die
    /// drei Kontextwerte gezielt wieder, behaelt aber Router-/Profil-Env.
    func gptRouterCoreEnvironment() -> [String: String]? {
        guard gptBackendEnabledResolver() else { return nil }

        let fastModeEnabled = gptFastModeEnabledResolver()
        let configuredPickerModel = gptPickerModelResolver()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultModel = gptDefaultModelResolver()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pickerModel = configuredPickerModel.isEmpty
            ? (defaultModel.isEmpty ? AppPreferences.claudeGPTCanonicalModel : defaultModel)
            : configuredPickerModel
        let contextWindow = normalizedGPTContextWindow()
        let effectivePickerModel = ClaudeGPTModelAlias.supportedEffectiveModel(
            pickerModel,
            fastEnabled: fastModeEnabled,
            contextWindow: contextWindow
        ) ?? ClaudeGPTModelAlias.supportedEffectiveModel(
            AppPreferences.claudeGPTCanonicalModel,
            fastEnabled: fastModeEnabled,
            contextWindow: contextWindow
        )!
        let isFastPickerModel = effectivePickerModel.hasSuffix("-fast")
        let supportedDescription = contextWindow > ClaudeGPTModelAlias.maximumKnownSharedContextWindow
            ? "experimentelles 372k-Profil: nur GPT-5.6 Sol"
            : "unterstützt: GPT-5.6 Sol/Terra/Luna, GPT-5.5 und GPT-5.4/Mini"
        let pickerDescription = isFastPickerModel
            ? "Priority-Tier (1,5× Speed, 2,5× Credits) — \(supportedDescription)"
            : "Standard-Tier — \(supportedDescription)"
        let gptContextWindow = String(contextWindow)
        var environment = [
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(gptRouterPortResolver())",
            "ANTHROPIC_CUSTOM_MODEL_OPTION": effectivePickerModel,
            "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME": effectivePickerModel,
            "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION": pickerDescription,
            "CLAUDE_CODE_ALWAYS_ENABLE_EFFORT": "1",
            // Drei gemeinsame Invarianten für jede direkt gestartete CLI.
            // MAX_CONTEXT beschreibt das gewählte GPT-Profil; bei 372k lässt
            // der Modellguard ausschließlich Sol zu. Der 1M-Deckel lässt native
            // Fable-/Opus-Modelle ungekappt, die eigene Variable korrigiert nur
            // die GPT-Anzeige. Background-Worker erhalten dasselbe Trio über
            // ihr internes session-scoped Settings-`env`.
            "CLAUDE_CODE_MAX_CONTEXT_TOKENS": gptContextWindow,
            "CLAUDE_CODE_AUTO_COMPACT_WINDOW": String(Self.routerAutoCompactCeiling),
            "WHISPERM8_GPT56_CONTEXT_WINDOW": gptContextWindow,
        ]
        let subagentModel = gptSubagentModelResolver()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !subagentModel.isEmpty {
            let effectiveSubagentModel = ClaudeGPTModelAlias.supportedSubagentModel(
                subagentModel,
                fastEnabled: fastModeEnabled,
                contextWindow: contextWindow
            ) ?? ClaudeGPTModelAlias.supportedSubagentModel(
                AppPreferences.claudeGPTCanonicalModel,
                fastEnabled: fastModeEnabled,
                contextWindow: contextWindow
            )!
            environment["CLAUDE_CODE_SUBAGENT_MODEL"] = effectiveSubagentModel
        }
        return environment
    }

    /// Zusaetzliche CLI-Argumente, die VOR den session-spezifischen Args
    /// eingefuegt werden — z. B. `--settings <path>` fuer die Hook-Bridge
    /// (Phase 5). `nil` wenn kein zusaetzlicher Inject gewuenscht ist.
    var extraLaunchArguments: [String] = []

    /// Zusaetzliche Env-Overrides fuer den PTY-Prozess — z. B. das Env eines
    /// Context-Profils (`ClaudeContextSettingsBuilder.processEnvironmentOverlay`).
    /// Prioritaet: LoginShellEnvironment < DIESE < Account-CLAUDE_CONFIG_DIR
    /// < Router-Env. Ein Context-Profil kann Account-Routing und GPT-Router
    /// damit nie kapern (reservierte Keys sind zusaetzlich vorgefiltert).
    var extraEnvironmentOverrides: [String: String] = [:]

    func command(for session: AgentChatSession, project: AgentProject) throws -> AgentLaunchCommand {
        guard FileManager.default.fileExists(atPath: project.path) else {
            throw AgentCommandError.missingProject(project.path)
        }

        // Terminals sind kein Agent-Launch: der `provider` ist nur ein
        // Schema-Platzhalter, das Kommando ist immer die Login-Shell.
        if session.isTerminal {
            return terminalCommand(project: project)
        }

        switch session.provider {
        case .codex:
            return try codexCommand(for: session, project: project)
        case .claude:
            return try claudeCommand(for: session, project: project)
        }
    }

    /// Baut den Launch für einen normalen Terminal-Tab: die Login-Shell des
    /// Users, interaktiv + als Login-Shell gestartet (`-i -l`), damit
    /// .zprofile/.zshrc gesourct werden und PATH/Prompt/Aliases exakt wie in
    /// Terminal.app aussehen. Keine Session-Args, kein Resume — jede neue
    /// Shell ist frisch.
    private func terminalCommand(project: AgentProject) -> AgentLaunchCommand {
        AgentLaunchCommand(
            executablePath: shellResolver(),
            arguments: ["-i", "-l"],
            workingDirectory: project.path,
            keyboardProfile: .plainShell
        )
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

        // Account-Profil der Session (Multi-Account): laeuft die Session unter
        // einem Zusatz-Account, bekommt der Launch dessen CLAUDE_CONFIG_DIR.
        // Der Stempel ist Session-stabil — Resume MUSS unter demselben
        // Config-Dir laufen, unter dem die Session erstellt wurde. (Fuer
        // Resumes wird der Stempel unten zusaetzlich gegen den realen
        // Transcript-Ablageort verifiziert — die Platte ist SSoT.)
        // Das Context-Profil-Env liegt UNTER dem Account-Env — bei
        // Key-Kollision gewinnt das Account-Profil.
        let extraEnvironment = extraEnvironmentOverrides
        let accountEnvironment: (String?) -> [String: String] = { profileName in
            extraEnvironment.merging(
                claudeProfileEnvironmentResolver(profileName)
            ) { _, account in account }
        }
        let profileEnvironment = accountEnvironment(session.claudeProfileName)

        let routerEnabled = gptBackendEnabledResolver()
        let fastModeEnabled = routerEnabled && gptFastModeEnabledResolver()
        let gptBackendModel: String? = {
            guard routerEnabled else { return nil }
            let model = session.claudeBackendModel?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !model.isEmpty else { return nil }
            let contextWindow = normalizedGPTContextWindow()
            if let supported = ClaudeGPTModelAlias.supportedEffectiveModel(
                model,
                fastEnabled: fastModeEnabled,
                contextWindow: contextWindow
            ) {
                return supported
            }

            // Das 372k-Profil ist ein Sol-only-Opt-in. Ein für den normalen
            // 272k-Vertrag bekanntes Modell fällt bei einem FRISCHEN Start auf
            // Sol zurück, statt still ohne GPT-Stempel als Claude zu starten.
            // Unbekannte GPT-IDs bleiben weiterhin abgelehnt; Resume/Fork folgt
            // unverändert der Transcript-Wahl und benötigt für Nicht-Sol das
            // Standardprofil.
            guard contextWindow == ClaudeGPTContextProfile.experimentalSol372K.rawValue,
                  let canonical = ClaudeGPTModelAlias.canonicalGPTModel(model),
                  ClaudeGPTModelAlias.maximumContextWindow(for: canonical) != nil else {
                return nil
            }
            return ClaudeGPTModelAlias.supportedEffectiveModel(
                AppPreferences.claudeGPTCanonicalModel,
                fastEnabled: fastModeEnabled,
                contextWindow: contextWindow
            )
        }()

        // Der Router gilt bewusst fuer jede Claude-PTY-Session. So koennen
        // auch Sessions ohne GPT-Stempel spaeter per `/model` wechseln und
        // konfigurierte GPT-Subagents verwenden.
        let applyRouterEnvironment: ([String: String], Bool) -> [String: String] = {
            baseEnvironment, includesGPTTuning in
            guard let routerEnvironment = gptRouterCoreEnvironment() else {
                return baseEnvironment
            }

            var environment = baseEnvironment.merging(routerEnvironment) { _, router in router }
            if includesGPTTuning {
                environment["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = "gpt-5.4-mini"
                environment["CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY"] = "3"
            }
            return environment
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
                keyboardProfile: .claudeAgentsView,
                environmentOverrides: applyRouterEnvironment(profileEnvironment, false)
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
            var attachEnvironment = applyRouterEnvironment(profileEnvironment, false)
            // Der Attach-Prozess kennt das reale Worker-Fenster nicht: Claude
            // Code 2.1.216 persistiert die drei Kontextwerte nicht garantiert
            // in den Supervisor-Worker. Ohne Metadaten zeigt die Statusline den
            // vom Worker gemeldeten Wert statt faelschlich 272k zu erfinden.
            for key in Self.gptContextEnvironmentKeys {
                attachEnvironment.removeValue(forKey: key)
            }
            return AgentLaunchCommand(
                executablePath: executable,
                arguments: arguments,
                workingDirectory: project.path,
                keyboardProfile: .claudeCodeChat,
                environmentOverrides: attachEnvironment,
                environmentRemovals: Set(Self.gptContextEnvironmentKeys)
            )
        }

        // Resume-Ziel bestimmen: Fork-Quelle vor gebundener eigener ID.
        var resumeSessionID: String?
        var isFork = false
        if let forkSource = session.forkSourceSessionID, !forkSource.isEmpty,
           (session.externalSessionID?.isEmpty ?? true) {
            // Fork: vom Stand der Quell-Session resumen, aber in eine NEUE
            // Session-ID abzweigen (Original bleibt unangetastet). Greift nur
            // solange die eigene ID noch nicht gebunden ist — sobald der
            // SessionStart-Hook `externalSessionID` gesetzt hat, läuft der
            // Resume über die neue Fork-ID (Pfad unten).
            resumeSessionID = forkSource
            isFork = true
        } else if session.hasLaunchedInitialPrompt,
                  let externalSessionID = session.externalSessionID,
                  !externalSessionID.isEmpty {
            // Resume NUR mit einer real von Claude vergebenen, gebundenen ID.
            resumeSessionID = externalSessionID
        }

        let resumeTranscriptURL = resumeSessionID.flatMap {
            claudeTranscriptLocator($0, project.path)
        }
        let legacyResumeModel: String? = {
            guard routerEnabled,
                  let resumeTranscriptURL,
                  let restoredModel = ClaudeTranscriptReader.lastAssistantModel(
                      fileURL: resumeTranscriptURL
                  ),
                  ClaudeGPTModelAlias.hasMemorySuffix(restoredModel) else {
                return nil
            }
            return ClaudeGPTModelAlias.supportedEffectiveModel(
                restoredModel,
                fastEnabled: false,
                contextWindow: normalizedGPTContextWindow()
            )
        }()

        var arguments: [String] = []
        // Vom Caller injizierte Args (z. B. `--settings <hook-settings.json>`)
        // kommen ganz vorne, damit Claude sie sicher beim Parse sieht.
        arguments.append(contentsOf: extraLaunchArguments)
        let userArguments = extraArgumentsResolver(.claude)
        // Nur Erststarts bekommen den normalen GPT-Modellstempel. Resume/Fork
        // restaurieren grundsaetzlich die Transcript-Wahl. Einzige Ausnahme:
        // alte GPT-Transcripts mit `[1m]` erhalten den suffixlosen, aus dem
        // letzten Assistant-Payload gelesenen Modellwert, weil der Router den
        // kapazitaetsverfaelschenden Suffix heute ablehnt. User-Extras folgen
        // danach und behalten last-flag-wins.
        let hasResumeArgument = resumeSessionID != nil
            || Self.argumentsContainResumeFlag(arguments)
            || Self.argumentsContainResumeFlag(userArguments)
        let shouldApplyGPTModelStamp = !hasResumeArgument && gptBackendModel != nil
        if shouldApplyGPTModelStamp, let gptBackendModel {
            arguments.append(contentsOf: ["--model", gptBackendModel])
        } else if hasResumeArgument, let legacyResumeModel {
            arguments.append(contentsOf: ["--model", legacyResumeModel])
        }
        // User-defined extras (z. B. --dangerously-skip-permissions) vor dem
        // Resume-Block, damit sie auch beim Resume durchgehen.
        arguments.append(contentsOf: userArguments)
        // Sonst: frischer Start OHNE `--session-id`. Claude vergibt die Session-
        // ID selbst; SessionStart-Hook + Indexer-Merge binden die REALE, von
        // Claude geschriebene ID nach (Weg B / Superset-Prinzip). Ein erzwungenes
        // `--session-id` war die Wurzel der „No conversation found"-Fehler —
        // Claude persistierte nicht zuverlässig unter der vorgegebenen ID, und
        // beim Resume zeigte die ID dann ins Leere.

        // Resume-Selbstheilung: `claude --resume` sucht das Transcript NUR im
        // `projects/`-Root seines Config-Dirs. Zeigt der Session-Stempel auf
        // einen anderen Root als den, in dem die JSONL wirklich liegt (z. B.
        // veralteter Stempel, extern verschobenes Transcript, historischer
        // Env-Leak), waere der Chat „No conversation found" — deshalb schlaegt
        // der REALE Ablageort den Stempel. Kein Fund (z. B. Transcript noch
        // nicht geschrieben) → Stempel wie bisher.
        var effectiveProfileEnvironment = profileEnvironment
        if let resumeSessionID,
           let transcript = resumeTranscriptURL {
            let actualProfile = ClaudeAccountProfiles.profileName(forTranscriptPath: transcript.path)
            if actualProfile != session.claudeProfileName {
                Logger.agentStore.warning(
                    "claude_profile_stamp_mismatch session=\(resumeSessionID, privacy: .public) stamped=\(session.claudeProfileName ?? "main", privacy: .public) actual=\(actualProfile ?? "main", privacy: .public) — Launch folgt dem realen Transcript-Root"
                )
                effectiveProfileEnvironment = accountEnvironment(actualProfile)
            }
        }

        if let resumeSessionID {
            arguments.append(contentsOf: ["--resume", resumeSessionID])
            if isFork {
                arguments.append("--fork-session")
            }
        }

        if !session.hasLaunchedInitialPrompt,
           let initialPrompt = session.initialPrompt,
           !initialPrompt.isEmpty {
            arguments.append(initialPrompt)
        }

        effectiveProfileEnvironment = applyRouterEnvironment(
            effectiveProfileEnvironment,
            shouldApplyGPTModelStamp
        )

        return AgentLaunchCommand(
            executablePath: executable,
            arguments: arguments,
            workingDirectory: project.path,
            keyboardProfile: .claudeCodeChat,
            environmentOverrides: effectiveProfileEnvironment
        )
    }

    /// Baut die Argv fuer einen `claude --bg`-Spawn-Subprocess. Wird vom
    /// `BackgroundAgentSpawner` benutzt — der Spawn selbst ist *kein*
    /// PTY-Launch, sondern ein einmaliger Subprocess der die Short-ID
    /// auf stdout druckt und dann beendet. Wir bauen die Args trotzdem
    /// hier zentral, damit Spawn und Attach in derselben Code-Linie liegen.
    ///
    /// Reihenfolge: Das interne `--settings` muss vor `--bg` stehen, damit
    /// Claude die Hook-Konfiguration vor dem Session-Setup einliest. Wenn diese
    /// interne Datei gesetzt ist, werden konkurrierende User-`--settings` aus
    /// den Extras entfernt; ohne interne Datei bleiben die Extras unverändert.
    /// `--agent` und `--permission-mode` sind optionale Flags vor dem Prompt.
    static func backgroundSpawnArguments(
        initialPrompt: String,
        settingsFilePath: String? = nil,
        subAgent: String? = nil,
        permissionMode: String? = nil,
        extraArguments: [String] = []
    ) -> [String] {
        var args: [String] = []
        var effectiveExtraArguments = extraArguments
        if let path = settingsFilePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            var sanitizedArguments: [String] = []
            var index = 0
            while index < extraArguments.count {
                let argument = extraArguments[index]
                if argument == "--settings" {
                    // Claude konsumiert nach der separaten Form immer genau das
                    // naechste Token als Wert — auch wenn es wie ein Flag aussieht.
                    index += 1
                    if index < extraArguments.count {
                        index += 1
                    }
                } else if argument.hasPrefix("--settings=") {
                    index += 1
                } else {
                    sanitizedArguments.append(argument)
                    index += 1
                }
            }
            effectiveExtraArguments = sanitizedArguments
            args.append(contentsOf: ["--settings", path])
        }
        args.append("--bg")
        if let agent = subAgent?.trimmingCharacters(in: .whitespacesAndNewlines), !agent.isEmpty {
            args.append(contentsOf: ["--agent", agent])
        }
        if let mode = permissionMode?.trimmingCharacters(in: .whitespacesAndNewlines), !mode.isEmpty {
            args.append(contentsOf: ["--permission-mode", mode])
        }
        args.append(contentsOf: effectiveExtraArguments)
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
