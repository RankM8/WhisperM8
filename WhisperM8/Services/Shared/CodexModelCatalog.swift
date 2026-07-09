import Foundation

// MARK: - Katalog-Typen

/// Ein Reasoning-Level („Thinking"), wie es die Codex CLI für ein Modell
/// meldet (`supported_reasoning_levels` in ~/.codex/models_cache.json).
struct CodexEffortOption: Equatable, Sendable, Identifiable {
    /// TOML-Wert für `model_reasoning_effort`, z.B. "xhigh", "ultra".
    let effort: String
    /// Server-Beschreibung („Greater reasoning depth …"), optional.
    let detail: String?

    var id: String { effort }
    var displayName: String { CodexModelCatalog.effortDisplayName(effort) }
}

/// Ein Codex-Modell aus dem Katalog (Cache ∪ eingebetteter Fallback).
struct CodexCatalogModel: Equatable, Sendable, Identifiable {
    let slug: String
    let displayName: String
    let detail: String?
    /// `default_reasoning_level` des Servers.
    let defaultEffort: String
    /// In Server-Reihenfolge (aufsteigend: low → … → ultra).
    let efforts: [CodexEffortOption]
    /// TUI-Picker-Reihenfolge. ACHTUNG: 0 ist NICHT das neueste Modell
    /// (gpt-5.5 hat 0, gpt-5.6-sol hat 1) — für „neuestes" siehe
    /// `CodexModelCatalog.frontierModel`.
    let priority: Int

    var id: String { slug }
    /// Höchstes verfügbares Level — „höchste Qualität immer wählbar".
    var maxEffort: String { efforts.last?.effort ?? defaultEffort }

    func supportsEffort(_ effort: String) -> Bool {
        efforts.contains { $0.effort == effort }
    }
}

// MARK: - Katalog-Snapshot

/// Immutable Snapshot des Modellkatalogs. Quelle ist die von der Codex CLI
/// selbst gepflegte ~/.codex/models_cache.json (Server-Fetch mit ETag),
/// gemergt mit einem eingebetteten Fallback: der Cache kann dem installierten
/// Binary hinterherhinken (beobachtet: Cache 0.142.5 ohne die gpt-5.6-Familie
/// neben Binary 0.144.0) — die effektive TUI-Liste ist Binary-Defaults ∪ Cache,
/// und genau das bildet der Merge nach.
struct CodexModelCatalog: Equatable, Sendable {
    /// Nur `visibility == "list"`, sortiert nach `priority` (TUI-Reihenfolge).
    let models: [CodexCatalogModel]
    /// `fetched_at` aus dem Cache; nil = reiner Fallback (Datei fehlt/kaputt).
    let fetchedAt: Date?

    // MARK: Lookup

    func model(slug: String) -> CodexCatalogModel? {
        models.first { $0.slug == slug }
    }

    /// Efforts des Modells; unbekannter Slug → konservative Basis-Levels,
    /// damit der Picker nie leer ist.
    func efforts(forModelSlug slug: String) -> [CodexEffortOption] {
        model(slug: slug)?.efforts ?? Self.baselineEfforts
    }

    /// Erstes gelistetes Modell (kleinste priority) — der TUI-Default.
    var defaultModel: CodexCatalogModel? { models.first }

    /// „Neuestes" Modell: höchste aus dem Slug geparste Version
    /// (`gpt-<major>.<minor>`), Tie-Break kleinste priority — heute
    /// gpt-5.6-sol. `priority` allein taugt nicht (gpt-5.5 = 0).
    /// Kein parsebarer Slug im Katalog → defaultModel.
    var frontierModel: CodexCatalogModel? {
        let versioned = models.compactMap { model -> (CodexCatalogModel, Int, Int)? in
            guard let version = Self.parseSlugVersion(model.slug) else { return nil }
            return (model, version.major, version.minor)
        }
        let best = versioned.max { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
            // Gleiche Version: kleinere priority gewinnt (sol vor terra).
            return lhs.0.priority > rhs.0.priority
        }
        return best?.0 ?? defaultModel
    }

    // MARK: Anzeige

    /// Displayname eines Slugs; unbekannt → Slug roh (kein stilles Umdeuten).
    func modelDisplayName(_ slug: String) -> String {
        model(slug: slug)?.displayName ?? slug
    }

    /// Bekannte Effort-Werte hübsch, unbekannte capitalized — so bleiben
    /// künftige Level nutzbar, bevor die App sie kennt.
    static func effortDisplayName(_ effort: String) -> String {
        switch effort {
        case "minimal": return "Minimal"
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra High"
        case "max": return "Max"
        case "ultra": return "Ultra"
        default: return effort.capitalized
        }
    }

    // MARK: Picker-Optionen

    /// Slugs für den Modell-Picker. Ein persistierter Wert außerhalb des
    /// Katalogs bleibt als erster Eintrag sichtbar — die Auswahl springt nie
    /// still auf ein anderes Modell um.
    func pickerModelSlugs(including selected: String) -> [String] {
        let slugs = models.map(\.slug)
        let trimmed = selected.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed != CodexModelSelection.autoRawValue,
              !slugs.contains(trimmed) else { return slugs }
        return [trimmed] + slugs
    }

    /// Effort-Werte für den Thinking-Picker des gegebenen Modells; analog
    /// bleibt ein unbekannter persistierter Effort sichtbar.
    func pickerEffortValues(forModelSlug slug: String, including selected: String) -> [String] {
        let values = efforts(forModelSlug: slug).map(\.effort)
        let trimmed = selected.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !values.contains(trimmed) else { return values }
        return [trimmed] + values
    }

    // MARK: Konflikt-Auflösung

    /// Level, auf das die UI bei einem Modellwechsel-Konflikt setzt (gewähltes
    /// Level vom neuen Modell nicht unterstützt, z.B. ultra → luna).
    /// Beschlossen: immer "high" — jedes bekannte Modell unterstützt es und
    /// es ist zugleich der App-Standard.
    static let conflictFallbackEffort = "high"

    /// true, wenn die UI beim Wechsel auf `slug` den Effort umsetzen soll:
    /// Modell ist katalogbekannt, Effort ist katalogbekannt (irgendeines
    /// Modells), aber vom Ziel-Modell nicht unterstützt. Gänzlich unbekannte
    /// Efforts (neuer als der Katalog) bleiben unangetastet.
    func shouldReplaceEffort(_ effort: String, forModelSlug slug: String) -> Bool {
        guard let target = model(slug: slug) else { return false }
        guard !target.supportsEffort(effort) else { return false }
        let knownAnywhere = models.contains { $0.supportsEffort(effort) }
            || Self.baselineEfforts.contains { $0.effort == effort }
        return knownAnywhere
    }

    // MARK: Konstanten

    /// Basis-Levels für Modelle, die der Katalog (noch) nicht kennt.
    static let baselineEfforts: [CodexEffortOption] = [
        CodexEffortOption(effort: "low", detail: nil),
        CodexEffortOption(effort: "medium", detail: nil),
        CodexEffortOption(effort: "high", detail: nil),
        CodexEffortOption(effort: "xhigh", detail: nil),
    ]

    /// Eingebetteter Fallback-Katalog — Stand Codex CLI 0.144.0 (2026-07-09).
    /// Bei Codex-Updates gelegentlich gegen ~/.codex/models_cache.json
    /// abgleichen; er muss nur „mindestens so gut wie das älteste unterstützte
    /// Binary" sein, der Cache gewinnt pro Slug.
    static let fallback = CodexModelCatalog(
        models: [
            CodexCatalogModel(
                slug: "gpt-5.5", displayName: "GPT-5.5",
                detail: "Frontier model for complex coding, research, and real-world work.",
                defaultEffort: "medium", efforts: effortRange(through: "xhigh"), priority: 0
            ),
            CodexCatalogModel(
                slug: "gpt-5.6-sol", displayName: "GPT-5.6-Sol",
                detail: "Latest frontier agentic coding model.",
                defaultEffort: "low", efforts: effortRange(through: "ultra"), priority: 1
            ),
            CodexCatalogModel(
                slug: "gpt-5.6-terra", displayName: "GPT-5.6-Terra",
                detail: "Balanced agentic coding model for everyday work.",
                defaultEffort: "medium", efforts: effortRange(through: "ultra"), priority: 2
            ),
            CodexCatalogModel(
                slug: "gpt-5.6-luna", displayName: "GPT-5.6-Luna",
                detail: "Fast and affordable agentic coding model.",
                defaultEffort: "medium", efforts: effortRange(through: "max"), priority: 3
            ),
            CodexCatalogModel(
                slug: "gpt-5.4", displayName: "GPT-5.4",
                detail: "Strong model for everyday coding.",
                defaultEffort: "medium", efforts: effortRange(through: "xhigh"), priority: 16
            ),
            CodexCatalogModel(
                slug: "gpt-5.4-mini", displayName: "GPT-5.4-Mini",
                detail: "Small, fast, and cost-efficient model for simpler coding tasks.",
                defaultEffort: "medium", efforts: effortRange(through: "xhigh"), priority: 23
            ),
            CodexCatalogModel(
                slug: "gpt-5.3-codex-spark", displayName: "GPT-5.3-Codex-Spark",
                detail: "Ultra-fast coding model.",
                defaultEffort: "high", efforts: effortRange(through: "xhigh"), priority: 26
            ),
        ],
        fetchedAt: nil
    )

    /// Kanonische Effort-Rangfolge (aufsteigend) — Quelle für den Fallback.
    private static let canonicalEffortOrder = ["low", "medium", "high", "xhigh", "max", "ultra"]

    private static func effortRange(through highest: String) -> [CodexEffortOption] {
        guard let end = canonicalEffortOrder.firstIndex(of: highest) else { return baselineEfforts }
        return canonicalEffortOrder[...end].map { CodexEffortOption(effort: $0, detail: nil) }
    }

    /// `gpt-<major>.<minor>…` → (major, minor); alles andere nil.
    /// (Bewusst ohne Regex-Literal — BareSlashRegexLiterals ist in SwiftPM
    /// nicht aktiviert, und für zwei Zahlen reicht String-Parsing.)
    static func parseSlugVersion(_ slug: String) -> (major: Int, minor: Int)? {
        guard slug.hasPrefix("gpt-") else { return nil }
        let version = slug.dropFirst("gpt-".count)
        let majorDigits = version.prefix { $0.isNumber }
        guard !majorDigits.isEmpty,
              version.dropFirst(majorDigits.count).first == "." else { return nil }
        let minorDigits = version.dropFirst(majorDigits.count + 1).prefix { $0.isNumber }
        guard !minorDigits.isEmpty,
              let major = Int(majorDigits), let minor = Int(minorDigits) else { return nil }
        return (major, minor)
    }
}

// MARK: - Auto-Modell-Sentinel

/// „Auto"-Eintrag im Modell-Picker: persistiert wird der Sentinel, aufgelöst
/// wird er erst an den Egress-Grenzen (CodexInvocation, Session-Erzeugung) —
/// so profitiert jede Nutzung automatisch vom jeweils neuesten Frontier-Modell.
enum CodexModelSelection {
    static let autoRawValue = "auto"

    /// "auto" → Slug des Frontier-Modells; alles andere unverändert.
    static func resolveSlug(
        _ raw: String,
        catalog: CodexModelCatalog = CodexModelCatalogStore.shared.catalog()
    ) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed == autoRawValue else { return raw }
        return catalog.frontierModel?.slug
            ?? CodexPostProcessingModel.defaultModel.rawValue
    }
}

// MARK: - Store (liest ~/.codex/models_cache.json)

/// Liest und cached den Modellkatalog. Strikt read-only gegenüber ~/.codex/.
/// Re-parst nur, wenn sich (mtime, size) der Datei geändert haben — billig
/// genug, um bei jedem Settings-Öffnen aufgerufen zu werden. Kein
/// FileEventSource: die Datei ändert sich selten und die Konsumenten sind
/// kurzlebige Settings-Views.
final class CodexModelCatalogStore: @unchecked Sendable {
    static let shared = CodexModelCatalogStore()

    private let fileURL: URL
    private let dataLoader: (URL) throws -> Data
    private let statLoader: (URL) -> (mtime: Date, size: Int)?

    private let lock = NSLock()
    private var cached: (stat: (mtime: Date, size: Int), catalog: CodexModelCatalog)?

    /// DI-Closures für Tests (Fixture-JSON, Stat-Fakes) — Konvention wie überall.
    init(
        fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/models_cache.json"),
        dataLoader: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) },
        statLoader: @escaping (URL) -> (mtime: Date, size: Int)? = { url in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date,
                  let size = attrs[.size] as? Int else { return nil }
            return (mtime, size)
        }
    ) {
        self.fileURL = fileURL
        self.dataLoader = dataLoader
        self.statLoader = statLoader
    }

    /// Aktueller Katalog-Snapshot. Datei fehlt/kaputt → letzter guter Parse,
    /// sonst der eingebettete Fallback (der Merge läuft in beiden Fällen).
    func catalog() -> CodexModelCatalog {
        lock.lock()
        defer { lock.unlock() }

        guard let stat = statLoader(fileURL) else {
            return cached?.catalog ?? CodexModelCatalog.fallback
        }
        if let cached, cached.stat == stat {
            return cached.catalog
        }
        guard let data = try? dataLoader(fileURL),
              let parsed = Self.parse(data) else {
            return cached?.catalog ?? CodexModelCatalog.fallback
        }
        cached = (stat, parsed)
        return parsed
    }

    // MARK: Parsing

    /// DTOs nur für die benötigten Felder; alles Übrige (base_instructions
    /// u.v.m., Datei ist ~276 KB) wird ignoriert. Zukunftsnotiz: der Cache
    /// liefert auch `service_tiers`/`additional_speed_tiers` — Kandidat, um
    /// den Speed-Picker (CodexServiceTier) ebenfalls dynamisch zu machen.
    private struct CacheFile: Decodable {
        let fetchedAt: String?
        let models: [LenientModel]

        enum CodingKeys: String, CodingKey {
            case fetchedAt = "fetched_at"
            case models
        }
    }

    /// Ein einzelnes kaputtes/unerwartetes Modell-Objekt darf nicht den ganzen
    /// Cache verwerfen — pro Element `try?`.
    private struct LenientModel: Decodable {
        let model: CacheModel?
        init(from decoder: Decoder) throws {
            model = try? CacheModel(from: decoder)
        }
    }

    private struct CacheModel: Decodable {
        let slug: String
        let displayName: String?
        let description: String?
        let defaultReasoningLevel: String?
        let supportedReasoningLevels: [CacheEffort]?
        let visibility: String?
        let priority: Int?

        enum CodingKeys: String, CodingKey {
            case slug
            case displayName = "display_name"
            case description
            case defaultReasoningLevel = "default_reasoning_level"
            case supportedReasoningLevels = "supported_reasoning_levels"
            case visibility
            case priority
        }
    }

    private struct CacheEffort: Decodable {
        let effort: String
        let description: String?
    }

    static func parse(_ data: Data) -> CodexModelCatalog? {
        guard let file = try? JSONDecoder().decode(CacheFile.self, from: data) else { return nil }

        let cacheModels: [(model: CodexCatalogModel, visibility: String?)] = file.models
            .compactMap(\.model)
            .compactMap { raw in
                guard !raw.slug.isEmpty else { return nil }
                let efforts = (raw.supportedReasoningLevels ?? []).map {
                    CodexEffortOption(effort: $0.effort, detail: $0.description)
                }
                let model = CodexCatalogModel(
                    slug: raw.slug,
                    displayName: raw.displayName ?? raw.slug,
                    detail: raw.description,
                    defaultEffort: raw.defaultReasoningLevel
                        ?? efforts.first?.effort ?? "medium",
                    efforts: efforts.isEmpty ? CodexModelCatalog.baselineEfforts : efforts,
                    priority: raw.priority ?? Int.max
                )
                return (model, raw.visibility)
            }
        guard !cacheModels.isEmpty else { return nil }

        return merged(cacheModels: cacheModels, fetchedAt: parseDate(file.fetchedAt))
    }

    /// Merge = Cache ∪ Fallback: pro Slug gewinnt der Cache; Fallback-Modelle,
    /// die der Cache (noch) nicht kennt, werden ergänzt. Erst danach der
    /// visibility-Filter (codex-auto-review ist "hide") und die priority-Sort.
    private static func merged(cacheModels: [(model: CodexCatalogModel, visibility: String?)], fetchedAt: Date?) -> CodexModelCatalog {
        var bySlug: [String: (model: CodexCatalogModel, visibility: String?)] = [:]
        for entry in cacheModels { bySlug[entry.model.slug] = entry }
        for fallbackModel in CodexModelCatalog.fallback.models where bySlug[fallbackModel.slug] == nil {
            bySlug[fallbackModel.slug] = (fallbackModel, "list")
        }
        let visible = bySlug.values
            .filter { ($0.visibility ?? "list") == "list" }
            .map(\.model)
            .sorted { lhs, rhs in
                lhs.priority != rhs.priority ? lhs.priority < rhs.priority : lhs.slug < rhs.slug
            }
        return CodexModelCatalog(models: visible, fetchedAt: fetchedAt)
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }
}
