import Foundation

struct OutputMode: Identifiable, Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        case raw
        case builtIn
        case custom
    }

    let id: String
    var name: String
    var shortLabel: String
    var kind: Kind
    var templateID: String?
    var isEnabled: Bool
    var isDefault: Bool
    var contextPolicy: ContextCapturePolicy
    var pasteVisualAttachments: Bool
    /// Optional Codex model override for this mode. `nil` means the global
    /// Codex post-processing model preference is used.
    var codexModelRawOverride: String?
    /// Optional Codex reasoning override for this mode. `nil` means the global
    /// Codex reasoning preference is used.
    var codexReasoningEffortRawOverride: String?
    /// Optional Codex service-tier override for this mode. `nil` means the
    /// global Codex service-tier preference is used.
    var codexServiceTierRawOverride: String?

    var usesPostProcessing: Bool {
        kind != .raw
    }

    /// Modus benötigt Codex-Enrichment (Post-Processing). Alle Modi außer Raw.
    /// Alias für Lesbarkeit an den Profil-/Verfügbarkeits-Aufrufstellen.
    var isCodexDependent: Bool {
        usesPostProcessing
    }

    init(
        id: String,
        name: String,
        shortLabel: String,
        kind: Kind,
        templateID: String?,
        isEnabled: Bool,
        isDefault: Bool,
        contextPolicy: ContextCapturePolicy = .off,
        pasteVisualAttachments: Bool? = nil,
        codexModelRawOverride: String? = nil,
        codexReasoningEffortRawOverride: String? = nil,
        codexServiceTierRawOverride: String? = nil
    ) {
        self.id = id
        self.name = name
        self.shortLabel = shortLabel
        self.kind = kind
        self.templateID = templateID
        self.isEnabled = isEnabled
        self.isDefault = isDefault
        self.contextPolicy = contextPolicy
        self.pasteVisualAttachments = pasteVisualAttachments
            ?? Self.defaultPasteVisualAttachments(for: id, kind: kind, contextPolicy: contextPolicy)
        self.codexModelRawOverride = codexModelRawOverride
        self.codexReasoningEffortRawOverride = codexReasoningEffortRawOverride
        self.codexServiceTierRawOverride = codexServiceTierRawOverride
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case shortLabel
        case kind
        case templateID
        case isEnabled
        case isDefault
        case contextPolicy
        case pasteVisualAttachments
        case codexModelRawOverride
        case codexReasoningEffortRawOverride
        case codexServiceTierRawOverride
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        shortLabel = try container.decode(String.self, forKey: .shortLabel)
        kind = try container.decode(Kind.self, forKey: .kind)
        templateID = try container.decodeIfPresent(String.self, forKey: .templateID)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        isDefault = try container.decode(Bool.self, forKey: .isDefault)
        contextPolicy = try container.decodeIfPresent(ContextCapturePolicy.self, forKey: .contextPolicy)
            ?? Self.defaultContextPolicy(for: id)
        pasteVisualAttachments = try container.decodeIfPresent(Bool.self, forKey: .pasteVisualAttachments)
            ?? Self.defaultPasteVisualAttachments(for: id, kind: kind, contextPolicy: contextPolicy)
        codexModelRawOverride = try container.decodeIfPresent(String.self, forKey: .codexModelRawOverride)
        codexReasoningEffortRawOverride = try container.decodeIfPresent(String.self, forKey: .codexReasoningEffortRawOverride)
        codexServiceTierRawOverride = try container.decodeIfPresent(String.self, forKey: .codexServiceTierRawOverride)
    }

    func resolvedCodexModelRaw(defaultModelRaw: String = AppPreferences.shared.codexPostProcessingModelRaw) -> String {
        guard let override = codexModelRawOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
              !override.isEmpty else {
            return defaultModelRaw
        }
        return override
    }

    func resolvedCodexReasoningEffortRaw(defaultReasoningEffortRaw: String = AppPreferences.shared.codexReasoningEffortRaw) -> String {
        guard let override = codexReasoningEffortRawOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
              !override.isEmpty else {
            return defaultReasoningEffortRaw
        }
        return override
    }

    func resolvedCodexServiceTierRaw(defaultServiceTierRaw: String = AppPreferences.shared.codexServiceTierRaw) -> String {
        guard let override = codexServiceTierRawOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
              !override.isEmpty else {
            return defaultServiceTierRaw
        }
        return override
    }
}

extension OutputMode {
    static let rawID = "raw"
    static let cleanID = "clean"
    static let promptID = "prompt"
    static let chatID = "chat"
    static let taskID = "task"
    static let emailID = "email"
    static let slackID = "slack"
    static let whatsappID = "whatsapp"
    static let notesID = "notes"

    static let builtInModes: [OutputMode] = [
        OutputMode(
            id: rawID,
            name: "Raw",
            shortLabel: "Raw",
            kind: .raw,
            templateID: nil,
            isEnabled: true,
            isDefault: true
        ),
        OutputMode(
            id: cleanID,
            name: "Clean",
            shortLabel: "Clean",
            kind: .builtIn,
            templateID: PostProcessingTemplate.cleanID,
            isEnabled: true,
            isDefault: false
        ),
        OutputMode(
            id: promptID,
            name: "Prompt",
            shortLabel: "Prompt",
            kind: .builtIn,
            templateID: PostProcessingTemplate.promptID,
            isEnabled: true,
            isDefault: false,
            contextPolicy: .auto,
            pasteVisualAttachments: true
        ),
        OutputMode(
            id: chatID,
            name: "Chat",
            shortLabel: "Chat",
            kind: .builtIn,
            templateID: PostProcessingTemplate.chatID,
            isEnabled: true,
            isDefault: false,
            contextPolicy: .auto,
            pasteVisualAttachments: true
        ),
        OutputMode(
            id: taskID,
            name: "Task",
            shortLabel: "Task",
            kind: .builtIn,
            templateID: PostProcessingTemplate.taskID,
            isEnabled: true,
            isDefault: false,
            contextPolicy: .auto,
            pasteVisualAttachments: true
        ),
        OutputMode(
            id: emailID,
            name: "Email",
            shortLabel: "Mail",
            kind: .builtIn,
            templateID: PostProcessingTemplate.emailID,
            isEnabled: true,
            isDefault: false,
            contextPolicy: .auto,
            pasteVisualAttachments: true
        ),
        OutputMode(
            id: slackID,
            name: "Slack",
            shortLabel: "Slack",
            kind: .builtIn,
            templateID: PostProcessingTemplate.slackID,
            isEnabled: true,
            isDefault: false,
            contextPolicy: .auto,
            pasteVisualAttachments: true
        ),
        OutputMode(
            id: whatsappID,
            name: "WhatsApp",
            shortLabel: "WA",
            kind: .builtIn,
            templateID: PostProcessingTemplate.whatsappID,
            isEnabled: true,
            isDefault: false,
            contextPolicy: .auto,
            pasteVisualAttachments: true
        ),
        OutputMode(
            id: notesID,
            name: "Notes",
            shortLabel: "Notes",
            kind: .builtIn,
            templateID: PostProcessingTemplate.notesID,
            isEnabled: true,
            isDefault: false
        )
    ]

    static func mode(for id: String?) -> OutputMode {
        OutputModeStore().mode(for: id)
    }

    static func defaultMode(profile: AppUsageProfile = AppPreferences.shared.usageProfile) -> OutputMode {
        let resolved = OutputModeStore().mode(for: AppPreferences.shared.defaultOutputModeID)
        // Ohne Enrichment (Dictation-only) darf niemals ein Codex-Modus aktiv sein —
        // die gespeicherte Präferenz bleibt erhalten (für spätere Freischaltung), effektiv
        // wird aber auf Raw zurückgefallen.
        if !profile.wantsCodexEnrichment && resolved.isCodexDependent {
            return OutputModeStore().mode(for: OutputMode.rawID)
        }
        return resolved
    }

    static var enabledBuiltInModes: [OutputMode] {
        OutputModeStore().enabledModes
    }

    /// Im Aufnahme-Overlay tatsächlich wählbare Modi — profilabhängig. Ohne Enrichment
    /// (Dictation-only) bleiben nur die Codex-freien Modi (Raw), damit der Hot-Path sauber
    /// bleibt (Discoverability der Codex-Modi passiert stattdessen in Settings/Onboarding).
    static func availableBuiltInModes(profile: AppUsageProfile = AppPreferences.shared.usageProfile) -> [OutputMode] {
        let enabled = enabledBuiltInModes
        guard profile.wantsCodexEnrichment else {
            return enabled.filter { !$0.isCodexDependent }
        }
        return enabled
    }

    static func defaultContextPolicy(for id: String) -> ContextCapturePolicy {
        switch id {
        case promptID, chatID, taskID, emailID, slackID, whatsappID:
            return .auto
        default:
            return .off
        }
    }

    static func defaultPasteVisualAttachments(
        for id: String,
        kind: Kind = .builtIn,
        contextPolicy: ContextCapturePolicy = .off
    ) -> Bool {
        if kind == .custom {
            return contextPolicy != .off
        }

        switch id {
        case promptID, chatID, taskID, emailID, slackID, whatsappID:
            return true
        default:
            return false
        }
    }
}
