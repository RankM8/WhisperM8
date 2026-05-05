import Foundation

enum ContextCapturePolicy: String, CaseIterable, Identifiable, Codable {
    case off
    case auto
    case required

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .auto:
            return "Auto when selected"
        case .required:
            return "Required"
        }
    }

    var detail: String {
        switch self {
        case .off:
            return "This mode ignores selected text."
        case .auto:
            return "Selected text is used as context when WhisperM8 can capture it."
        case .required:
            return "This mode expects selected text. If none is captured, post-processing will stop."
        }
    }
}

struct SelectedContext: Equatable, Codable {
    var text: String
    var sourceAppName: String?
    var sourceBundleIdentifier: String?

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static let empty = SelectedContext(
        text: "",
        sourceAppName: nil,
        sourceBundleIdentifier: nil
    )
}
