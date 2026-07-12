import Foundation

enum AgentProvider: String, CaseIterable, Identifiable, Codable, Equatable {
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        }
    }

    var systemImage: String {
        switch self {
        case .codex:
            return "sparkles"
        case .claude:
            return "seal"
        }
    }

    /// Bundle-Asset-Name für das offizielle Provider-Logo.
    /// Liegt in `WhisperM8/Resources/<assetName>.png` (+ @2x).
    var assetName: String {
        switch self {
        case .codex:
            return "ProviderCodex"
        case .claude:
            return "ProviderClaude"
        }
    }
}

/// Unterscheidet zwischen normaler interaktiver Claude/Codex-Session
/// (`.chat`), dem "Claude Agents View"-Dashboard (`.agentView`),
/// das via `claude agents` (ab Claude Code 2.1.139) eine Multi-Session-
/// Verwaltungsoberflaeche startet, und einer einzelnen, vom Supervisor
/// gehosteten Background-Session (`.backgroundChat`), die wir via
/// `claude --bg "<prompt>"` selbst spawnen und per `claude attach <id>`
/// in einem PTY rendern.
///
/// Agent View ist semantisch kein einzelner Chat sondern ein TUI-Dashboard
/// fuer Background-Sessions — daher andere Behandlung: kein Auto-Naming,
/// kein Transcript (es gibt keine eigene JSONL), keine Hook-Bridge.
///
/// Background-Chats verhalten sich aus UI-Sicht wie ein normaler Chat
/// (ein Tab, eine JSONL, Auto-Naming) — aber der Prozess ist vom Claude-
/// Supervisor-Daemon (`~/.claude/daemon/`) geparented, nicht von uns. Wir
/// muessen die vom Supervisor vergebene Short-ID festhalten.
enum AgentSessionKind: String, Codable, Equatable {
    /// Default — `claude` oder `codex` als normale interaktive Session.
    case chat
    /// `claude agents` — Background-Session-Dashboard. Nur fuer Claude.
    case agentView
    /// `claude --bg` + `claude attach <id>` — eine einzelne Background-
    /// Session, gerendert in unserem PTY-Tab. Nur fuer Claude.
    case backgroundChat
    /// Headless Codex-Subagent-Job, superviselt vom whisperm8-CLI
    /// (`whisperm8 agent run`). Kein PTY — Detail-View statt Terminal-Tab;
    /// nach Übernahme läuft er über den normalen codex-resume-Pfad weiter.
    case subagentJob
    /// Normales interaktives Terminal: die Login-Shell des Users im
    /// Projektverzeichnis, KEIN Agent. Keine externe Session-ID, kein
    /// Transcript, keine Hook-Bridge, kein Auto-Naming/Resume — der
    /// `provider` ist nur ein inerter Platzhalter (non-optional im Schema).
    case terminal

    var displayName: String {
        switch self {
        case .chat: return "Chat"
        case .agentView: return "Agent View"
        case .backgroundChat: return "Hintergrund-Agent"
        case .subagentJob: return "Subagent"
        case .terminal: return "Terminal"
        }
    }

    /// Lenienter Decode-Helfer: unbekannte Raw-Values (z.B. ein Kind aus
    /// einer NEUEREN App-Version) werden `nil` statt eines Decode-Throws —
    /// sonst würde ein Downgrade-Build beim Workspace-Load die GESAMTE
    /// AgentSessions.json als korrupt verwerfen (Backup + .empty).
    static func lenientDecode(_ raw: String?) -> AgentSessionKind? {
        raw.flatMap(AgentSessionKind.init(rawValue:))
    }
}

enum AgentChatStatus: String, Codable, Equatable {
    case pending
    case running
    case closed
    case archived

    var displayName: String {
        switch self {
        case .pending:
            return "Pending"
        case .running:
            return "Running"
        case .closed:
            return "Closed"
        case .archived:
            return "Archived"
        }
    }
}

/// Feinkörniger Live-Status einer aktiven Agent-Session, abgeleitet aus dem
/// JSONL-Transcript des Subprocess (Claude/Codex). Im Gegensatz zu
/// `AgentChatStatus` wird dieser Wert **nicht persistiert** — er existiert nur
/// solange der Process lebt und wird vom `AgentSessionRuntimeWatcher` gepflegt.
///
/// Mapping-Logik (vereinfacht):
/// - `.working` — JSONL wurde kürzlich erweitert (Subprocess arbeitet aktiv)
/// - `.awaitingInput` — Heuristik: Tool-Use offen + JSONL längere Zeit ruhig
///   (häufiges Signal für Permission-Prompt). Bei `--dangerously-skip-permissions`
///   tritt dieser Status fast nie auf.
/// - `.idle` — Subprocess läuft, hat aber Antwort fertig, wartet auf neuen Prompt
/// - `.stopped` — Subprocess beendet (ExitCode 0 / kein ExitCode)
/// - `.errored` — Subprocess beendet mit ExitCode != 0
enum AgentSessionRuntimeStatus: String, Codable, Equatable {
    case working
    case awaitingInput
    case idle
    case stopped
    case errored

    var isLive: Bool {
        switch self {
        case .working, .awaitingInput, .idle:
            return true
        case .stopped, .errored:
            return false
        }
    }
}

struct AgentProject: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    var path: String
    var color: String
    var lastBranch: String?
    var createdAt: Date
    var updatedAt: Date
    /// `true` wenn das Projekt vom Nutzer manuell hinzugefügt wurde, `nil`/`false` für Auto-Imports.
    /// Optional damit ältere Workspace-Dateien ohne dieses Feld weiter dekodiert werden können.
    var createdManually: Bool?
    /// Pfad eines im Projekt-Repo gefundenen Icons relativ zu `path` — wird vom
    /// `AgentProjectIconResolver` gesetzt (z. B. "public/favicon.png"). Bleibt
    /// auch dann gültig, wenn das Repo verschoben wird, solange der relative
    /// Pfad stabil ist.
    var iconRelativePath: String?
    /// Absoluter Pfad eines vom User explizit ausgewählten Icons (z. B. via
    /// File-Picker auf ein Bild außerhalb des Repos). Hat Vorrang vor
    /// `iconRelativePath`.
    var customIconAbsolutePath: String?
    /// `true` wenn der Auto-Resolver schon mindestens einmal versucht hat ein
    /// Icon zu finden — verhindert wiederholte Filesystem-Scans bei jedem
    /// Workspace-Reload. Manuelles "Auto-Icon erkennen" setzt das wieder auf
    /// `nil`/`false`, um einen Re-Lookup zu erzwingen.
    var iconAutoLookupAttempted: Bool?
    /// User-gesteuerte Sortierreihenfolge in der Sidebar. `nil` für Legacy-
    /// Projekte ohne explizite Reihenfolge — die werden weiterhin nach
    /// `updatedAt` (jüngste zuerst) einsortiert. Sobald der User per
    /// Drag-and-Drop reorderdt, bekommen ALLE sichtbaren Projekte
    /// fortlaufende `sortIndex`-Werte (0, 1, 2, …) und das Feld ist nicht
    /// mehr `nil`.
    var sortIndex: Int?

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        color: String = AgentProjectColor.palette[0],
        lastBranch: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        createdManually: Bool? = nil,
        iconRelativePath: String? = nil,
        customIconAbsolutePath: String? = nil,
        iconAutoLookupAttempted: Bool? = nil,
        sortIndex: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.color = color
        self.lastBranch = lastBranch
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdManually = createdManually
        self.iconRelativePath = iconRelativePath
        self.customIconAbsolutePath = customIconAbsolutePath
        self.iconAutoLookupAttempted = iconAutoLookupAttempted
        self.sortIndex = sortIndex
    }

    var isManuallyAdded: Bool { createdManually == true }

    /// Effektiver Icon-Pfad in Vorrang-Reihenfolge: User-gewähltes File >
    /// Auto-erkanntes Repo-Icon > nichts. Liefert `nil`, wenn beide Felder
    /// leer sind oder der File auf der Disk verschwunden ist.
    var resolvedIconURL: URL? {
        if let custom = customIconAbsolutePath, !custom.isEmpty {
            let url = URL(fileURLWithPath: custom)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        if let relative = iconRelativePath, !relative.isEmpty {
            let url = URL(fileURLWithPath: path).appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}

struct AgentChatSession: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var provider: AgentProvider
    var projectID: UUID
    var externalSessionID: String?
    var title: String
    var model: String
    var reasoningEffort: String
    var status: AgentChatStatus
    var color: String?
    var groupName: String?
    var sortIndex: Int?
    var initialPrompt: String?
    var imagePaths: [String]
    var hasLaunchedInitialPrompt: Bool
    var shouldLaunchOnOpen: Bool?
    var createdAt: Date
    var lastActivityAt: Date
    /// Zeitpunkt der Archivierung durch den Nutzer. `nil` solange die Session
    /// nicht archiviert ist bzw. nach „Wiederherstellen" aus dem Archiv.
    /// Primärer Sortier-Key des Archiv-Sheets (nicht `lastActivityAt`, das der
    /// Indexer bei Re-Scans auch für archivierte Sessions weiter bumpt).
    var archivedAt: Date?
    /// `true` wenn die Session vom Nutzer manuell erstellt wurde, `nil`/`false` für Auto-Imports.
    var createdManually: Bool?
    /// `true` wenn der aktuelle `title` automatisch generiert wurde (vom Auto-Namer
    /// nach Session-End). `false` wenn der User den Namen manuell geändert hat —
    /// dann **niemals** überschreiben. `nil` für Legacy-Sessions ohne dieses Flag,
    /// behandelt wie `true` (auto-Naming darf eingreifen).
    var titleIsAutoGenerated: Bool?
    /// Zeitstempel des letzten erfolgreich abgeschlossenen Agent-Turns
    /// (`stop_reason: end_turn` o. ä. im JSONL). Wird vom Runtime-Watcher gesetzt
    /// und vom Auto-Namer als „mindestens ein vollständiger Turn vorhanden"-Bedingung
    /// genutzt, bevor er einen Title generieren darf.
    var lastTurnAt: Date?
    /// Inhaltliche Zusammenfassung der Session. Vom `AgentSessionSummarizer`
    /// generiert, wenn die Session geschlossen oder im Detail-View geöffnet wird.
    /// `nil` solange noch nichts erzeugt wurde — die UI zeigt dann einen Hinweis
    /// + Generieren-Button.
    var summary: AgentSessionSummary?
    /// Art der Session: normaler interaktiver Chat, Claude Agents View
    /// oder eine einzelne Background-Session.
    /// `nil` in Legacy-Workspaces — wird beim Dekodieren auf `.chat` gesetzt.
    var kind: AgentSessionKind?
    /// Short-ID (8-stelliger Hex-Suffix), die Claude beim `claude --bg`-Spawn
    /// auf stdout druckt ("backgrounded · <id>"). Nur fuer `.backgroundChat`-
    /// Sessions gesetzt; erst nach erfolgreichem Spawn vorhanden. Wird fuer
    /// `claude attach/logs/stop/respawn/rm` benoetigt.
    var backgroundShortID: String?
    /// Optionaler Sub-Agent-Name (aus `~/.claude/agents/` oder `.claude/agents/`),
    /// den wir beim Spawn als `--agent <name>` mitgeben. `nil` = Default-Agent.
    var backgroundSubAgent: String?
    /// Optionaler Permission-Mode (`acceptEdits`, `plan`, `auto`, `dontAsk`,
    /// `bypassPermissions`), den wir beim Spawn als `--permission-mode <mode>`
    /// mitgeben. `nil` = `defaultMode` aus den Settings des cwds.
    var backgroundPermissionMode: String?
    /// Quell-Session-ID (Claude) eines Forks. Solange die eigene
    /// `externalSessionID` noch nicht gebunden ist, startet die Session als
    /// `claude --resume <forkSourceSessionID> --fork-session` — sie übernimmt
    /// den Stand der Quelle und zweigt in eine NEUE Session-ID ab (die der
    /// SessionStart-Hook bindet). `nil` für normale Sessions.
    var forkSourceSessionID: String?
    /// Short-ID des Subagent-Jobs (= Directory-Name unter agent-jobs/).
    /// Nur fuer `.subagentJob`; wird nach `agent rm` genil-t, damit der
    /// Indexer die Codex-Session danach normal adoptieren darf.
    var subagentJobShortID: String?
    /// Claude-`externalSessionID` der Session, die den Job gespawnt hat
    /// (`--parent`). Grundlage der Parent-Child-Einrückung in der Sidebar.
    var subagentParentSessionID: String?
    /// Effektives Working Directory des Jobs (ggf. Worktree-Pfad). Die
    /// Session hängt am Parent-PROJEKT, aber Resume/Übernahme muss im
    /// Job-cwd laufen — `codexCommand()` bevorzugt dieses Feld.
    var subagentCwd: String?
    /// Claude-Account-Profil, unter dem die Session läuft (`CLAUDE_CONFIG_DIR`
    /// = `~/.claude-profiles/<name>`). `nil` = Haupt-Account (`~/.claude`).
    /// Beim Erstellen aus dem aktiven Profil gestempelt und danach STABIL —
    /// ein `--resume` funktioniert nur unter demselben Config-Dir, unter dem
    /// die Session entstanden ist.
    var claudeProfileName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case provider
        case projectID
        case externalSessionID
        case title
        case model
        case reasoningEffort
        case status
        case color
        case groupName
        case sortIndex
        case initialPrompt
        case imagePaths
        case hasLaunchedInitialPrompt
        case shouldLaunchOnOpen
        case createdAt
        case lastActivityAt
        case archivedAt
        case createdManually
        case titleIsAutoGenerated
        case lastTurnAt
        case summary
        case kind
        case backgroundShortID
        case backgroundSubAgent
        case backgroundPermissionMode
        case forkSourceSessionID
        case subagentJobShortID
        case subagentParentSessionID
        case subagentCwd
        case claudeProfileName
    }

    init(
        id: UUID = UUID(),
        provider: AgentProvider,
        projectID: UUID,
        externalSessionID: String? = nil,
        title: String,
        model: String = CodexPostProcessingModel.defaultModel.rawValue,
        reasoningEffort: String = CodexReasoningEffort.defaultEffort.rawValue,
        status: AgentChatStatus = .pending,
        color: String? = nil,
        groupName: String? = nil,
        sortIndex: Int? = nil,
        initialPrompt: String? = nil,
        imagePaths: [String] = [],
        hasLaunchedInitialPrompt: Bool = false,
        shouldLaunchOnOpen: Bool = false,
        createdAt: Date = Date(),
        lastActivityAt: Date = Date(),
        archivedAt: Date? = nil,
        createdManually: Bool? = nil,
        titleIsAutoGenerated: Bool? = nil,
        lastTurnAt: Date? = nil,
        summary: AgentSessionSummary? = nil,
        kind: AgentSessionKind? = nil,
        backgroundShortID: String? = nil,
        backgroundSubAgent: String? = nil,
        backgroundPermissionMode: String? = nil,
        forkSourceSessionID: String? = nil,
        subagentJobShortID: String? = nil,
        subagentParentSessionID: String? = nil,
        subagentCwd: String? = nil,
        claudeProfileName: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.projectID = projectID
        self.externalSessionID = externalSessionID
        self.title = title
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.status = status
        self.color = color
        self.groupName = groupName
        self.sortIndex = sortIndex
        self.initialPrompt = initialPrompt
        self.imagePaths = imagePaths
        self.hasLaunchedInitialPrompt = hasLaunchedInitialPrompt
        self.shouldLaunchOnOpen = shouldLaunchOnOpen
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.archivedAt = archivedAt
        self.createdManually = createdManually
        self.titleIsAutoGenerated = titleIsAutoGenerated
        self.lastTurnAt = lastTurnAt
        self.summary = summary
        self.kind = kind
        self.backgroundShortID = backgroundShortID
        self.backgroundSubAgent = backgroundSubAgent
        self.backgroundPermissionMode = backgroundPermissionMode
        self.forkSourceSessionID = forkSourceSessionID
        self.subagentJobShortID = subagentJobShortID
        self.subagentParentSessionID = subagentParentSessionID
        self.subagentCwd = subagentCwd
        self.claudeProfileName = claudeProfileName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        provider = try container.decode(AgentProvider.self, forKey: .provider)
        projectID = try container.decode(UUID.self, forKey: .projectID)
        externalSessionID = try container.decodeIfPresent(String.self, forKey: .externalSessionID)
        title = try container.decode(String.self, forKey: .title)
        model = try container.decodeIfPresent(String.self, forKey: .model)
            ?? CodexPostProcessingModel.defaultModel.rawValue
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
            ?? CodexReasoningEffort.defaultEffort.rawValue
        status = try container.decodeIfPresent(AgentChatStatus.self, forKey: .status) ?? .pending
        color = try container.decodeIfPresent(String.self, forKey: .color)
        groupName = try container.decodeIfPresent(String.self, forKey: .groupName)
        sortIndex = try container.decodeIfPresent(Int.self, forKey: .sortIndex)
        initialPrompt = try container.decodeIfPresent(String.self, forKey: .initialPrompt)
        imagePaths = try container.decodeIfPresent([String].self, forKey: .imagePaths) ?? []
        hasLaunchedInitialPrompt = try container.decodeIfPresent(Bool.self, forKey: .hasLaunchedInitialPrompt) ?? false
        shouldLaunchOnOpen = try container.decodeIfPresent(Bool.self, forKey: .shouldLaunchOnOpen)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastActivityAt = try container.decode(Date.self, forKey: .lastActivityAt)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        createdManually = try container.decodeIfPresent(Bool.self, forKey: .createdManually)
        titleIsAutoGenerated = try container.decodeIfPresent(Bool.self, forKey: .titleIsAutoGenerated)
        lastTurnAt = try container.decodeIfPresent(Date.self, forKey: .lastTurnAt)
        summary = try container.decodeIfPresent(AgentSessionSummary.self, forKey: .summary)
        // Lenient: unbekannter kind-String (neuere App-Version) → nil →
        // .chat, statt den GESAMTEN Workspace-Decode scheitern zu lassen.
        kind = AgentSessionKind.lenientDecode(try container.decodeIfPresent(String.self, forKey: .kind))
        backgroundShortID = try container.decodeIfPresent(String.self, forKey: .backgroundShortID)
        backgroundSubAgent = try container.decodeIfPresent(String.self, forKey: .backgroundSubAgent)
        backgroundPermissionMode = try container.decodeIfPresent(String.self, forKey: .backgroundPermissionMode)
        forkSourceSessionID = try container.decodeIfPresent(String.self, forKey: .forkSourceSessionID)
        subagentJobShortID = try container.decodeIfPresent(String.self, forKey: .subagentJobShortID)
        subagentParentSessionID = try container.decodeIfPresent(String.self, forKey: .subagentParentSessionID)
        subagentCwd = try container.decodeIfPresent(String.self, forKey: .subagentCwd)
        claudeProfileName = try container.decodeIfPresent(String.self, forKey: .claudeProfileName)
    }

    var isManuallyCreated: Bool { createdManually == true }

    /// `true` wenn diese Session forkbar ist: ein normaler Claude-Chat mit
    /// bereits gebundener Session-ID (Resume-Quelle vorhanden). Background-
    /// Agents, Agent Views und Codex-Chats sind nicht forkbar.
    var isForkable: Bool {
        provider == .claude
            && effectiveKind == .chat
            && (externalSessionID.map { !$0.isEmpty } ?? false)
    }

    /// Effektive Session-Art. Legacy-Sessions ohne `kind`-Feld werden als
    /// `.chat` interpretiert (vor Einfuehrung von Agent View war das die
    /// einzige Variante).
    var effectiveKind: AgentSessionKind { kind ?? .chat }

    var isAgentView: Bool { effectiveKind == .agentView }

    /// `true` wenn diese Session ein einzelner Background-Agent ist
    /// (`claude --bg` + `claude attach`).
    var isBackgroundChat: Bool { effectiveKind == .backgroundChat }

    /// `true` wenn diese Session ein Codex-Subagent-Job ist
    /// (whisperm8-CLI-Supervisor, kein PTY bis zur Übernahme).
    var isSubagentJob: Bool { effectiveKind == .subagentJob }

    /// `true` wenn diese Session ein normales Shell-Terminal ist
    /// (Login-Shell im Projekt-cwd, kein Agent).
    var isTerminal: Bool { effectiveKind == .terminal }

    /// `true` wenn der Background-Agent bereits vom Supervisor registriert
    /// ist (Short-ID vorhanden) — Voraussetzung fuer `claude attach/logs/stop`.
    var hasBackgroundShortID: Bool {
        guard let id = backgroundShortID else { return false }
        return !id.isEmpty
    }

    /// `true` wenn Auto-Naming den Title aktualisieren darf. Default-Verhalten
    /// für Legacy-Sessions (Flag = nil): erlaubt, sofern der Name noch generisch
    /// aussieht (Default-Provider-Title).
    var canAutoRenameTitle: Bool {
        if let flag = titleIsAutoGenerated {
            return flag
        }
        // Legacy: erlaube Auto-Rename nur, wenn der Title noch der Default ist.
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty
            || normalized == "Claude Chat"
            || normalized == "Codex Chat"
            || normalized.hasSuffix(" Chat")
    }

    var runtimeDisplayText: String {
        // Terminals haben keinen Agent-Provider — der `provider` ist nur
        // Schema-Platzhalter und darf hier nicht durchscheinen.
        if isTerminal {
            return "Terminal · Login-Shell"
        }
        switch provider {
        case .codex:
            return "Codex · \(model) · \(reasoningEffort)"
        case .claude:
            return "Claude · Claude Code"
        }
    }
}

/// Inhaltliche Zusammenfassung einer geschlossenen / resumebaren Session, vom
/// `AgentSessionSummarizer` aus dem Transcript generiert. Persistiert auf der
/// `AgentChatSession` damit ein einmal generiertes Summary nicht bei jedem
/// Window-Öffnen neu durch das CLI muss.
struct AgentSessionSummary: Codable, Equatable, Hashable {
    /// Ein bis zwei Sätze fürs schnelle Wiedererkennen (oben groß im Detail-View).
    var headline: String
    /// Mehrere Absätze: Aufgabe, Änderungen, letzter Stand, offene Punkte.
    /// Markdown ist erlaubt — die UI rendert es als plain text mit Zeilenumbrüchen.
    var details: String
    /// Wann der Summary erzeugt wurde — Anzeige als „Vor 3 Stunden" o. ä.
    var generatedAt: Date
    /// Heuristischer Hash über Filesize+mtime des Transcripts. Wenn das Transcript
    /// seit der Generierung gewachsen ist, betrachten wir den Summary als stale
    /// und triggern Re-Generation. Optional damit alte JSONs migrierbar bleiben.
    var transcriptDigest: String?
    /// Grober Abschluss-Status aus dem Summarizer: abgeschlossen|offen|unterbrochen.
    var status: String?
    /// Deterministisch aus dem Transcript extrahierte Fakten (Commits/Tests/
    /// Dateien) — das LLM schreibt nur headline/details, nie SHAs.
    var evidence: Evidence?

    struct Evidence: Codable, Equatable, Hashable {
        struct Commit: Codable, Equatable, Hashable {
            var sha: String
            var message: String
        }
        struct TestRun: Codable, Equatable, Hashable {
            var command: String
            var passed: Bool
        }
        var commits: [Commit] = []
        var tests: [TestRun] = []
        var filesChanged: [String] = []

        var isEmpty: Bool { commits.isEmpty && tests.isEmpty && filesChanged.isEmpty }
    }
}

/// Leichter Zeiger auf den im Agent-Chats-Window aktuell aktiven Chat.
/// Wird von `AgentChatsView` in `AppState.activeAgentChat` gepusht und vom
/// `RecordingCoordinator` beim Start einer Aufnahme ins Context-Bundle übernommen,
/// damit der Recording-Overlay „Chat" als aktiven Kontext anzeigen kann.
struct AgentChatContextRef: Codable, Equatable, Hashable {
    let sessionID: UUID
    let provider: AgentProvider
    let projectName: String
    let projectPath: String
    let title: String
    let externalSessionID: String?
    /// Session-Art aus dem Roster. Optional fuer Backwards-Compat mit alten
    /// JSONs ohne dieses Feld — Default-Interpretation ist `.chat`.
    /// Wird vom `AgentChatTailExtractor` gebraucht um zwischen normalen
    /// Chats (JSONL via externalSessionID), Background-Chats (JSONL via
    /// Supervisor-Lookup) und Agent-View-Dashboards (kein Transcript)
    /// zu unterscheiden.
    var kind: AgentSessionKind? = nil
    /// Vom Supervisor vergebene Short-ID fuer `.backgroundChat`-Sessions.
    /// Wird via `~/.claude/jobs/<shortID>/state.json` → `linkScanPath`
    /// in einen JSONL-Pfad aufgeloest. Bei anderen Kinds bleibt das Feld
    /// `nil`. Optional fuer JSON-Kompatibilitaet.
    var backgroundShortID: String? = nil

    var effectiveKind: AgentSessionKind { kind ?? .chat }
}

struct AgentWorkspace: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var projects: [AgentProject]
    var sessions: [AgentChatSession]

    static let empty = AgentWorkspace(projects: [], sessions: [])

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case projects
        case sessions
    }

    init(schemaVersion: Int = Self.currentSchemaVersion, projects: [AgentProject], sessions: [AgentChatSession]) {
        self.schemaVersion = schemaVersion
        self.projects = projects
        self.sessions = sessions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        projects = try container.decode([AgentProject].self, forKey: .projects)
        sessions = try container.decode([AgentChatSession].self, forKey: .sessions)
    }
}

enum AgentProjectColor {
    static let palette = [
        "#0A84FF",
        "#32D74B",
        "#FF9F0A",
        "#BF5AF2",
        "#FF453A",
        "#64D2FF",
        "#FFD60A",
        "#AC8E68"
    ]
}

enum AgentChatColor {
    static let palette = [
        "#32D74B",
        "#FF9F0A",
        "#0A84FF",
        "#BF5AF2",
        "#FF453A",
        "#64D2FF",
        "#FFD60A",
        "#AC8E68"
    ]

    static func fallback(for session: AgentChatSession) -> String {
        if let color = session.color, !color.isEmpty {
            return color
        }
        switch session.provider {
        case .codex:
            return "#32D74B"
        case .claude:
            return "#FF9F0A"
        }
    }
}
