import Foundation

/// Sichtbare Kontextprofile des GPT-Backends. Das persistierte Preference-Feld
/// bleibt aus Kompatibilitätsgründen ein `Int`; dieser Typ definiert nur die
/// bewusst angebotenen Presets und ihre erwartete Claude-Code-Compact-Grenze.
enum ClaudeGPTContextProfile: Int, CaseIterable, Identifiable {
    case standard = 272_000
    case extended900K = 900_000

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .standard:
            return "Standard — 272k"
        case .extended900K:
            return "Erweitert — 900k (1M-Backend)"
        }
    }

    var expectedAutoCompactTokens: Int {
        switch self {
        case .standard:
            return 238_000
        case .extended900K:
            return 830_000
        }
    }

    static func matching(contextWindow: Int) -> Self? {
        Self(rawValue: contextWindow)
    }
}

/// Kanonisiert die von WhisperM8 erzeugten GPT-Modell-Aliasse und leitet die
/// Kapazitätsverträge des MixRouters aus dem Codex-Modellkatalog ab.
///
/// Einzige Quelle ist `~/.codex/models_cache.json` (∪ eingebetteter Fallback,
/// siehe `CodexModelCatalog`): Die Codex-CLI holt neue Modelle selbst vom
/// Server — sie erscheinen damit ohne Codeänderung im GPT-Backend. Statt
/// hart codierter Allowlists gelten Katalog-Metadaten: `supported_in_api`
/// (Backend-tauglich), `additional_speed_tiers` (Fast-Tier) und
/// `max_context_window` (1M-Klasse → erweitertes 900k-Profil). Der Sentinel
/// `auto` steht überall für das jeweils neueste Backend-Modell (Frontier).
enum ClaudeGPTModelAlias {
    /// Gemeinsame, konservative Kapazität aller freigegebenen GPT-Aliasse.
    static let maximumKnownSharedContextWindow = ClaudeGPTContextProfile.standard.rawValue

    /// Größtes auswählbares Profil. 900k ist per Direktmessung gegen den
    /// Codex-Upstream verifiziert (Subscription/OAuth): Sol, Terra, Luna und
    /// GPT-5.4 nahmen am 2026-08-18 903k–913k Input-Tokens an, ~924k wies der
    /// Upstream mit `request_too_large` ab; GPT-6 Astra nahm am 2026-09-06
    /// 905.911 Tokens an. Der Katalog meldet für diese Modelle
    /// `max_context_window` 872k — die Klassifikation „1M-Klasse" kommt aus
    /// dem Katalog, die Profilgröße bleibt der gemessene Wert.
    static let maximumConfigurableContextWindow =
        ClaudeGPTContextProfile.extended900K.rawValue

    /// Sentinel für „neuestes Backend-Modell". Wird an jeder Egress-Grenze
    /// (Stempel, Picker, Subagent-Definition, Router) auf den Frontier-Slug
    /// aufgelöst; `gpt-auto` ist als Schreibweise ebenfalls zulässig.
    static let autoModel = "auto"

    /// Katalogquelle — injizierbar, damit Tests deterministisch gegen den
    /// eingebetteten Fallback laufen statt gegen die lokale Cache-Datei.
    nonisolated(unsafe) static var catalogResolver: () -> CodexModelCatalog = {
        CodexModelCatalogStore.shared.catalog()
    }

    static func catalog() -> CodexModelCatalog { catalogResolver() }

    static func isAutoModel(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == autoModel || normalized == "gpt-\(autoModel)"
    }

    /// Slug des neuesten Backend-Modells. Der eingebettete Fallback garantiert
    /// immer einen Treffer — dieser Wert ersetzt die frühere Konstante
    /// `gpt-5.6-sol` an allen Fallback-Stellen.
    static func frontierModel(catalog: CodexModelCatalog = catalog()) -> String {
        catalog.gptBackendFrontierModel?.slug
            ?? CodexModelCatalog.fallback.gptBackendFrontierModel?.slug
            ?? "gpt-6-astra"
    }

    /// Alle Backend-Modelle in Katalogreihenfolge (ohne Fast-Varianten).
    static func backendModelSlugs(catalog: CodexModelCatalog = catalog()) -> [String] {
        catalog.gptBackendModels.map(\.slug)
    }

    /// Backend-Modelle, die das gegebene Profil tragen.
    static func backendModels(
        contextWindow: Int,
        catalog: CodexModelCatalog = catalog()
    ) -> [CodexCatalogModel] {
        catalog.gptBackendModels.filter { model in
            contextWindow <= maximumContextWindow(for: model)
        }
    }

    /// Vorschlagsliste für Settings-Felder: `auto` zuerst, dann jedes Modell,
    /// optional gefolgt von seiner Fast-Variante.
    static func suggestions(
        includeFastVariants: Bool,
        catalog: CodexModelCatalog = catalog()
    ) -> [String] {
        var result = [autoModel]
        for model in catalog.gptBackendModels {
            result.append(model.slug)
            if includeFastVariants, model.supportsFastTier {
                result.append("\(model.slug)-fast")
            }
        }
        return result
    }

    /// Kleines Modell für Claude Codes Haiku-Rolle (Web Search, Fetch,
    /// Hilfsaufrufe) im gegebenen Profil. Katalogreihenfolge rückwärts (die
    /// TUI listet die kleinen Modelle hinten): das erste Modell, das das
    /// Profil trägt, gewinnt; ein abgekündigtes oder für das Profil zu kleines
    /// Modell übergibt an seinen vom Server benannten Nachfolger (gpt-5.4-mini
    /// → gpt-5.6-luna). Ohne Treffer bleibt das Frontier-Modell — teurer, aber
    /// nie ein Modell, das der Router ablehnt (Befund 2026-09-08: Web Search
    /// scheiterte im 900k-Profil an einem fest verdrahteten Mini).
    static func smallModel(
        contextWindow: Int = maximumKnownSharedContextWindow,
        catalog: CodexModelCatalog = catalog()
    ) -> String {
        let supported = backendModels(contextWindow: contextWindow, catalog: catalog)
        func supports(_ slug: String) -> Bool {
            supported.contains { $0.slug == slug }
        }
        let candidates = catalog.models
            .filter { $0.slug.hasPrefix("gpt-") }
            .sorted { $0.priority > $1.priority }
        for candidate in candidates {
            if supports(candidate.slug) {
                return candidate.slug
            }
            if let upgrade = candidate.upgradeModel, supports(upgrade) {
                return upgrade
            }
        }
        return frontierModel(catalog: catalog)
    }

    /// Lesbare Aufzählung der Modelle eines Profils (Picker-Beschreibung,
    /// Router-Meldungen, Settings-Texte) — z. B. „gpt-6-astra, gpt-5.6-sol".
    static func supportedModelsSummary(
        contextWindow: Int,
        catalog: CodexModelCatalog = catalog()
    ) -> String {
        backendModels(contextWindow: contextWindow, catalog: catalog)
            .map(\.slug)
            .joined(separator: ", ")
    }

    private static func backendModel(
        _ base: String,
        catalog: CodexModelCatalog
    ) -> CodexCatalogModel? {
        guard let model = catalog.model(slug: base), model.isGPTBackendEligible else {
            return nil
        }
        return model
    }

    private static func stripFast(_ model: String) -> (base: String, hadFast: Bool) {
        model.hasSuffix("-fast")
            ? (String(model.dropLast("-fast".count)), true)
            : (model, false)
    }

    /// Lowercase, ohne Whitespace und ohne `[1m]`; `auto` → Frontier-Slug.
    /// Native Claude-Aliasse werden bewusst nicht kanonisiert, weil deren
    /// Suffix echte Modell-Metadaten ist.
    static func canonicalGPTModel(
        _ model: String,
        catalog: CodexModelCatalog = catalog()
    ) -> String? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        var normalized = trimmed.lowercased()
        if normalized.hasSuffix("[1m]") {
            normalized.removeLast(4)
        }
        if isAutoModel(normalized) {
            return frontierModel(catalog: catalog)
        }
        if normalized == "\(autoModel)-fast" || normalized == "gpt-\(autoModel)-fast" {
            return "\(frontierModel(catalog: catalog))-fast"
        }
        guard normalized.hasPrefix("gpt-") else { return nil }
        return normalized
    }

    static func hasMemorySuffix(_ model: String) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("gpt-")
            && trimmed.lowercased().hasSuffix("[1m]")
    }

    static func supportsFast(
        _ canonicalBaseModel: String,
        catalog: CodexModelCatalog = catalog()
    ) -> Bool {
        backendModel(canonicalBaseModel, catalog: catalog)?.supportsFastTier ?? false
    }

    private static func maximumContextWindow(for model: CodexCatalogModel) -> Int {
        model.supportsExtendedContextProfile
            ? maximumConfigurableContextWindow
            : maximumKnownSharedContextWindow
    }

    /// Obergrenze des Profils pro kanonischem Modell: 1M-Klasse laut Katalog
    /// → 900k, sonst 272k; unbekannte oder nicht backend-taugliche IDs → nil.
    static func maximumContextWindow(
        for canonicalModel: String,
        catalog: CodexModelCatalog = catalog()
    ) -> Int? {
        let base = stripFast(canonicalModel).base
        guard let model = backendModel(base, catalog: catalog) else { return nil }
        return maximumContextWindow(for: model)
    }

    static func isSupportedCanonicalModel(
        _ model: String,
        contextWindow: Int = maximumKnownSharedContextWindow,
        catalog: CodexModelCatalog = catalog()
    ) -> Bool {
        guard contextWindow > 0,
              let maximumContextWindow = maximumContextWindow(for: model, catalog: catalog),
              contextWindow <= maximumContextWindow else {
            return false
        }
        let (base, hasFast) = stripFast(model)
        guard backendModel(base, catalog: catalog) != nil else { return false }
        return !hasFast || supportsFast(base, catalog: catalog)
    }

    /// Subagent-Override: jedes Backend-Modell ist zulässig — die Wahl
    /// trifft der User, das Backend hält keine versteckte Zweitliste mehr.
    static func isSupportedSubagentCanonicalModel(
        _ model: String,
        contextWindow: Int = maximumKnownSharedContextWindow,
        catalog: CodexModelCatalog = catalog()
    ) -> Bool {
        isSupportedCanonicalModel(model, contextWindow: contextWindow, catalog: catalog)
    }

    static func supportedEffectiveModel(
        _ model: String,
        fastEnabled: Bool,
        contextWindow: Int = maximumKnownSharedContextWindow,
        catalog: CodexModelCatalog = catalog()
    ) -> String? {
        let effective = effectiveModel(model, fastEnabled: fastEnabled, catalog: catalog)
        return isSupportedCanonicalModel(effective, contextWindow: contextWindow, catalog: catalog)
            ? effective
            : nil
    }

    static func supportedSubagentModel(
        _ model: String,
        fastEnabled: Bool,
        contextWindow: Int = maximumKnownSharedContextWindow,
        catalog: CodexModelCatalog = catalog()
    ) -> String? {
        let effective = effectiveModel(model, fastEnabled: fastEnabled, catalog: catalog)
        return isSupportedSubagentCanonicalModel(
            effective,
            contextWindow: contextWindow,
            catalog: catalog
        ) ? effective : nil
    }

    /// Frontier-Modell im wirksamen Alias für das Profil — der Fallback an
    /// jeder Stelle, an der eine Konfiguration nicht trägt. Das Frontier-
    /// Modell ist per Katalog immer backend-tauglich; trägt es das Profil
    /// nicht, greift das nächste tragende Modell in Katalogreihenfolge.
    static func fallbackEffectiveModel(
        fastEnabled: Bool,
        contextWindow: Int = maximumKnownSharedContextWindow,
        catalog: CodexModelCatalog = catalog()
    ) -> String {
        if let frontier = supportedEffectiveModel(
            frontierModel(catalog: catalog),
            fastEnabled: fastEnabled,
            contextWindow: contextWindow,
            catalog: catalog
        ) {
            return frontier
        }
        for model in backendModels(contextWindow: contextWindow, catalog: catalog) {
            if let supported = supportedEffectiveModel(
                model.slug,
                fastEnabled: fastEnabled,
                contextWindow: contextWindow,
                catalog: catalog
            ) {
                return supported
            }
        }
        return effectiveModel(frontierModel(catalog: catalog), fastEnabled: fastEnabled, catalog: catalog)
    }

    /// Leitet den pro Request wirksamen Alias ab. Fast wird nur erzeugt, wenn
    /// der Katalog einen Priority-Tier belegt (GPT-5.4 Mini bleibt suffixlos).
    static func effectiveModel(
        _ model: String,
        fastEnabled: Bool,
        catalog: CodexModelCatalog = catalog()
    ) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let canonical = canonicalGPTModel(trimmed, catalog: catalog) else { return trimmed }
        let (base, hadFast) = stripFast(canonical)
        guard backendModel(base, catalog: catalog) != nil else { return canonical }
        if supportsFast(base, catalog: catalog), fastEnabled || hadFast {
            return "\(base)-fast"
        }
        return base
    }
}
