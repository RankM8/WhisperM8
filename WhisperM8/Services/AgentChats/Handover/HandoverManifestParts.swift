import Foundation

// MARK: - Manifest-Teile, die nur die App versteht

/// Abbild von `AgentLaunchCommand` fürs Manifest. Der Aufbewahrer reicht es
/// undurchsichtig weiter; die neue App baut daraus den Controller des
/// übernommenen Chats, ohne den Builder erneut zu fragen (der kennt nach dem
/// Neustart weder Attach-Fallback noch Abzweig-ID des damaligen Starts).
///
/// Geht nie auf die Platte: Die Umgebung kann Konto-Pfade und Profil-Header
/// enthalten, das Manifest selbst das Control-Token.
struct HandoverLaunchCommandSnapshot: Codable, Equatable {
    var executablePath: String
    var arguments: [String]
    var workingDirectory: String
    /// `claudeCodeChat`, `codexChat`, `claudeAgentsView`, `plainShell`.
    var keyboardProfile: String
    var environmentOverrides: [String: String]
    var environmentRemovals: [String]
    var isBackgroundAttachFallback: Bool
    var reboundExternalSessionID: String?

    init(_ command: AgentLaunchCommand) {
        executablePath = command.executablePath
        arguments = command.arguments
        workingDirectory = command.workingDirectory
        keyboardProfile = Self.name(of: command.keyboardProfile)
        environmentOverrides = command.environmentOverrides
        environmentRemovals = command.environmentRemovals.sorted()
        isBackgroundAttachFallback = command.isBackgroundAttachFallback
        reboundExternalSessionID = command.reboundExternalSessionID
    }

    /// Zurück zum Startkommando. `nil` bei unbekanntem Tastaturprofil: Eine
    /// ältere App kennt ein neueres Profil nicht und setzt dann lieber per
    /// `--resume` fort, als die Tasten falsch zu übersetzen.
    var launchCommand: AgentLaunchCommand? {
        guard let profile = Self.profile(named: keyboardProfile) else { return nil }
        return AgentLaunchCommand(
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            keyboardProfile: profile,
            environmentOverrides: environmentOverrides,
            environmentRemovals: Set(environmentRemovals),
            isBackgroundAttachFallback: isBackgroundAttachFallback,
            reboundExternalSessionID: reboundExternalSessionID
        )
    }

    static func name(of profile: TerminalKeyboardProfile) -> String {
        switch profile {
        case .claudeCodeChat: return "claudeCodeChat"
        case .codexChat: return "codexChat"
        case .claudeAgentsView: return "claudeAgentsView"
        case .plainShell: return "plainShell"
        }
    }

    static func profile(named name: String) -> TerminalKeyboardProfile? {
        switch name {
        case "claudeCodeChat": return .claudeCodeChat
        case "codexChat": return .codexChat
        case "claudeAgentsView": return .claudeAgentsView
        case "plainShell": return .plainShell
        default: return nil
        }
    }
}

/// Vorgemerkter Kontowechsel nach dem Turn (Entscheidung 9). Heute lebt er nur
/// im Speicher (`AccountSwitchCoordinator.pending`); ohne Manifest ginge er
/// beim Neustart verloren.
struct HandoverPendingAccountSwitch: Codable, Equatable {
    var targetProfile: String?
    var targetName: String
    /// Rohwert von `AccountSwitchPlanner.WaitReason`.
    var reason: String
    var since: Double

    @MainActor
    init(_ pending: AccountSwitchCoordinator.PendingSwitch) {
        targetProfile = pending.targetProfile
        targetName = pending.targetName
        reason = pending.reason.rawValue
        since = pending.since.timeIntervalSince1970
    }

    /// `nil` bei unbekanntem Grund (neuere App): dann verfällt die
    /// Vormerkung, wie heute bei jedem Neustart.
    @MainActor
    var pendingSwitch: AccountSwitchCoordinator.PendingSwitch? {
        guard let reason = AccountSwitchPlanner.WaitReason(rawValue: reason) else { return nil }
        return AccountSwitchCoordinator.PendingSwitch(
            targetProfile: targetProfile,
            targetName: targetName,
            reason: reason,
            since: Date(timeIntervalSince1970: since)
        )
    }
}

// MARK: - Umwandlung in den undurchsichtigen JSON-Wert

extension HandoverJSONValue {
    /// Kodiert einen Wert über JSON in die undurchsichtige Form des Manifests.
    init<Value: Encodable>(encoding value: Value) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(HandoverJSONValue.self, from: data)
    }

    /// Liest den Wert zurück; `nil`, wenn er nicht passt (andere Version).
    func decoded<Value: Decodable>(as type: Value.Type) -> Value? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Art des Chats im Manifest

/// Werte für `HandoverManifest.kind`. Der Aufbewahrer kennt sie nur als Text.
enum HandoverChatKind: String, Equatable {
    case claude
    case codex
    case terminal
    case attach

    /// Art aus Sitzung und Startkommando. `nil` für Arten, die nie übergeben
    /// werden (Agents-Ansicht, Subagent-Jobs ohne PTY).
    static func of(kind: AgentSessionKind, provider: AgentProvider, command: AgentLaunchCommand) -> HandoverChatKind? {
        if command.isClaudeAttach { return .attach }
        switch kind {
        case .terminal: return .terminal
        case .agentView, .subagentJob: return nil
        case .chat, .backgroundChat:
            return provider == .codex ? .codex : .claude
        }
    }
}
