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

    var usesPostProcessing: Bool {
        kind != .raw
    }

    init(
        id: String,
        name: String,
        shortLabel: String,
        kind: Kind,
        templateID: String?,
        isEnabled: Bool,
        isDefault: Bool,
        contextPolicy: ContextCapturePolicy = .off
    ) {
        self.id = id
        self.name = name
        self.shortLabel = shortLabel
        self.kind = kind
        self.templateID = templateID
        self.isEnabled = isEnabled
        self.isDefault = isDefault
        self.contextPolicy = contextPolicy
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
    }
}

extension OutputMode {
    static let rawID = "raw"
    static let cleanID = "clean"
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
            id: emailID,
            name: "Email",
            shortLabel: "Mail",
            kind: .builtIn,
            templateID: PostProcessingTemplate.emailID,
            isEnabled: true,
            isDefault: false,
            contextPolicy: .auto
        ),
        OutputMode(
            id: slackID,
            name: "Slack",
            shortLabel: "Slack",
            kind: .builtIn,
            templateID: PostProcessingTemplate.slackID,
            isEnabled: true,
            isDefault: false,
            contextPolicy: .auto
        ),
        OutputMode(
            id: whatsappID,
            name: "WhatsApp",
            shortLabel: "WA",
            kind: .builtIn,
            templateID: PostProcessingTemplate.whatsappID,
            isEnabled: true,
            isDefault: false,
            contextPolicy: .auto
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

    static func defaultMode() -> OutputMode {
        OutputModeStore().mode(for: AppPreferences.shared.defaultOutputModeID)
    }

    static var enabledBuiltInModes: [OutputMode] {
        OutputModeStore().enabledModes
    }

    static func defaultContextPolicy(for id: String) -> ContextCapturePolicy {
        switch id {
        case emailID, slackID, whatsappID:
            return .auto
        default:
            return .off
        }
    }
}
