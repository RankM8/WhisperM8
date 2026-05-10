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
        iconAutoLookupAttempted: Bool? = nil
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
        createdManually: Bool? = nil,
        titleIsAutoGenerated: Bool? = nil,
        lastTurnAt: Date? = nil
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
        self.createdManually = createdManually
        self.titleIsAutoGenerated = titleIsAutoGenerated
        self.lastTurnAt = lastTurnAt
    }

    var isManuallyCreated: Bool { createdManually == true }

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
        switch provider {
        case .codex:
            return "Codex · \(model) · \(reasoningEffort)"
        case .claude:
            return "Claude · Claude Code"
        }
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
}

struct AgentWorkspace: Codable, Equatable {
    var projects: [AgentProject]
    var sessions: [AgentChatSession]

    static let empty = AgentWorkspace(projects: [], sessions: [])
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
