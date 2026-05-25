import Foundation

enum CodexServiceTier: String, CaseIterable, Identifiable, Codable {
    case fast
    case standard

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast:
            return "Fast"
        case .standard:
            return "Standard"
        }
    }

    var detail: String {
        switch self {
        case .fast:
            return "Default. Uses Codex Fast mode for lower latency on supported ChatGPT plans."
        case .standard:
            return "Uses Codex standard routing and avoids the Fast-mode credit multiplier."
        }
    }

    var configArguments: [String] {
        switch self {
        case .fast:
            return [
                "-c", "features.fast_mode=true",
                "-c", "service_tier=fast"
            ]
        case .standard:
            return ["-c", "service_tier=default"]
        }
    }

    static let defaultTier: CodexServiceTier = .fast

    static func resolve(_ rawValue: String) -> CodexServiceTier {
        CodexServiceTier(rawValue: rawValue) ?? defaultTier
    }
}
