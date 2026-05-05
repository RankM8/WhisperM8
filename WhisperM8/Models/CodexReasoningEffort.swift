import Foundation

enum CodexReasoningEffort: String, CaseIterable, Identifiable, Codable {
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        case .xhigh:
            return "Extra High"
        }
    }

    var detail: String {
        switch self {
        case .low:
            return "Fastest. Good for simple cleanup."
        case .medium:
            return "Default. Balanced quality and speed."
        case .high:
            return "More careful for complex transformations."
        case .xhigh:
            return "Maximum reasoning depth for demanding templates."
        }
    }

    static let defaultEffort: CodexReasoningEffort = .medium

    static func resolve(_ rawValue: String) -> CodexReasoningEffort {
        CodexReasoningEffort(rawValue: rawValue) ?? defaultEffort
    }
}
