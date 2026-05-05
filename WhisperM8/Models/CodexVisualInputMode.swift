import Foundation

enum CodexVisualInputMode: String, CaseIterable, Identifiable, Codable {
    case auto
    case frames
    case video

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:
            return "Auto"
        case .frames:
            return "Frames"
        case .video:
            return "Video"
        }
    }

    var detail: String {
        switch self {
        case .auto:
            return "Uses the stable Codex CLI image path today, and can switch to direct video when the CLI exposes it."
        case .frames:
            return "Sends screenshots and visual summary frames with codex exec --image."
        case .video:
            return "Includes the full screen clip path in the prompt and still sends frames as fallback until codex exec supports direct video attachments."
        }
    }

    static let defaultMode: CodexVisualInputMode = .auto

    static func resolve(_ rawValue: String) -> CodexVisualInputMode {
        CodexVisualInputMode(rawValue: rawValue) ?? defaultMode
    }
}
