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

    var usesPostProcessing: Bool {
        kind != .raw
    }
}

extension OutputMode {
    static let rawID = "raw"
    static let cleanID = "clean"
    static let emailID = "email"
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
            isDefault: false
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
}
