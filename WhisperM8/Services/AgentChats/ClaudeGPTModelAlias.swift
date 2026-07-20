import Foundation

/// Leitet den pro Request wirksamen GPT-Modell-Alias fuer den Proxy ab.
enum ClaudeGPTModelAlias {
    static func effectiveModel(_ model: String, fastEnabled: Bool) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMemorySuffix = trimmed.lowercased().hasSuffix("[1m]")
        let memorySuffix = hasMemorySuffix ? String(trimmed.suffix(4)) : ""
        let baseModel = hasMemorySuffix ? String(trimmed.dropLast(4)) : trimmed

        guard fastEnabled,
              baseModel.hasPrefix("gpt-"),
              !baseModel.hasSuffix("-fast") else {
            return baseModel + memorySuffix
        }
        return baseModel + "-fast" + memorySuffix
    }
}
