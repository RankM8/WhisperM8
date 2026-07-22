import Foundation

/// Kanonisiert die von WhisperM8 erzeugten GPT-Modell-Aliasse und kapselt den
/// bekannten gemeinsamen Kapazitaetsvertrag des MixRouters.
enum ClaudeGPTModelAlias {
    /// Alle derzeit freigegebenen GPT-Aliasse besitzen mindestens dieses reale
    /// Kontextfenster. Groessere konfigurierte Werte muessen bis zu einer
    /// expliziten Katalog-Erweiterung konservativ abgelehnt werden.
    static let maximumKnownSharedContextWindow = 272_000

    private static let mainModelBases: Set<String> = [
        "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
        "gpt-5.5", "gpt-5.4", "gpt-5.4-mini",
    ]
    private static let subagentModelBases: Set<String> = [
        "gpt-5.6-sol", "gpt-5.6-terra",
    ]

    /// Lowercase, ohne Whitespace und ohne `[1m]`. Native Claude-Aliasse werden
    /// bewusst nicht kanonisiert, weil deren Suffix echte Modell-Metadaten ist.
    static func canonicalGPTModel(_ model: String) -> String? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        var normalized = trimmed.lowercased()
        guard normalized.hasPrefix("gpt-") else { return nil }
        if normalized.hasSuffix("[1m]") {
            normalized.removeLast(4)
        }
        return normalized
    }

    static func hasMemorySuffix(_ model: String) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("gpt-")
            && trimmed.lowercased().hasSuffix("[1m]")
    }

    static func supportsFast(_ canonicalBaseModel: String) -> Bool {
        mainModelBases.contains(canonicalBaseModel)
            && canonicalBaseModel != "gpt-5.4-mini"
    }

    static func isSupportedCanonicalModel(
        _ model: String,
        contextWindow: Int = maximumKnownSharedContextWindow
    ) -> Bool {
        guard contextWindow > 0,
              contextWindow <= maximumKnownSharedContextWindow else {
            return false
        }
        let hasFast = model.hasSuffix("-fast")
        let base = hasFast ? String(model.dropLast("-fast".count)) : model
        guard mainModelBases.contains(base) else { return false }
        return !hasFast || supportsFast(base)
    }

    static func isSupportedSubagentCanonicalModel(
        _ model: String,
        contextWindow: Int = maximumKnownSharedContextWindow
    ) -> Bool {
        guard isSupportedCanonicalModel(model, contextWindow: contextWindow) else {
            return false
        }
        let base = model.hasSuffix("-fast")
            ? String(model.dropLast("-fast".count))
            : model
        return subagentModelBases.contains(base)
    }

    static func supportedEffectiveModel(
        _ model: String,
        fastEnabled: Bool,
        contextWindow: Int = maximumKnownSharedContextWindow
    ) -> String? {
        let effective = effectiveModel(model, fastEnabled: fastEnabled)
        return isSupportedCanonicalModel(effective, contextWindow: contextWindow)
            ? effective
            : nil
    }

    static func supportedSubagentModel(
        _ model: String,
        fastEnabled: Bool,
        contextWindow: Int = maximumKnownSharedContextWindow
    ) -> String? {
        let effective = effectiveModel(model, fastEnabled: fastEnabled)
        return isSupportedSubagentCanonicalModel(effective, contextWindow: contextWindow)
            ? effective
            : nil
    }

    /// Leitet den pro Request wirksamen Alias ab. Fast wird nur erzeugt, wenn
    /// der lokale Modellkatalog einen Priority-Tier belegt. Insbesondere bleibt
    /// GPT-5.4 Mini auch bei aktivem Fast-Modus suffixlos.
    static func effectiveModel(_ model: String, fastEnabled: Bool) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let canonical = canonicalGPTModel(trimmed) else { return trimmed }
        let hadFast = canonical.hasSuffix("-fast")
        let base = hadFast ? String(canonical.dropLast("-fast".count)) : canonical
        guard mainModelBases.contains(base) else { return canonical }
        if supportsFast(base), fastEnabled || hadFast {
            return "\(base)-fast"
        }
        return base
    }
}
