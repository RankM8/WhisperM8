import Foundation

/// NUR NOCH Fallback-Konstanten (Default-Wert + Legacy-Referenz) — die
/// Picker-Quellen der Settings sind seit dem dynamischen Katalog
/// `CodexModelCatalog` (Services/Shared), der die Level pro Modell aus
/// ~/.codex/models_cache.json übernimmt (inkl. max/ultra, die hier bewusst
/// fehlen: dieses Enum muss nicht mehr vollständig sein).
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
            return "Balanced quality and speed."
        case .high:
            return "Default. More careful for complex transformations."
        case .xhigh:
            return "Maximum reasoning depth for demanding templates."
        }
    }

    /// Beschlossen 2026-07-09: High statt Medium — wirkt über die
    /// AppPreferences-Fallbacks sofort für alle Nutzer ohne expliziten Wert.
    static let defaultEffort: CodexReasoningEffort = .high

    static func resolve(_ rawValue: String) -> CodexReasoningEffort {
        CodexReasoningEffort(rawValue: rawValue) ?? defaultEffort
    }
}
