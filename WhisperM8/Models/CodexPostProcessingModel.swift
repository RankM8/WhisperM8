import Foundation

enum CodexPostProcessingModel: String, CaseIterable, Identifiable, Codable {
    case gpt55 = "gpt-5.5"
    case gpt54 = "gpt-5.4"
    case gpt52 = "gpt-5.2"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gpt55:
            return "GPT-5.5"
        case .gpt54:
            return "GPT-5.4"
        case .gpt52:
            return "GPT-5.2"
        }
    }

    var detail: String {
        switch self {
        case .gpt55:
            return "Default. Best quality when your Codex CLI supports it."
        case .gpt54:
            return "Strong fallback for newer Codex versions."
        case .gpt52:
            return "Compatible with the currently tested Codex CLI on this Mac."
        }
    }

    static let defaultModel: CodexPostProcessingModel = .gpt55

    static func resolve(_ rawValue: String) -> CodexPostProcessingModel {
        CodexPostProcessingModel(rawValue: rawValue) ?? defaultModel
    }
}
