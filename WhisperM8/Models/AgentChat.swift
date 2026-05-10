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

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        color: String = AgentProjectColor.palette[0],
        lastBranch: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        createdManually: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.color = color
        self.lastBranch = lastBranch
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdManually = createdManually
    }

    var isManuallyAdded: Bool { createdManually == true }
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
        createdManually: Bool? = nil
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
    }

    var isManuallyCreated: Bool { createdManually == true }

    var runtimeDisplayText: String {
        switch provider {
        case .codex:
            return "Codex · \(model) · \(reasoningEffort)"
        case .claude:
            return "Claude · Claude Code"
        }
    }
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
