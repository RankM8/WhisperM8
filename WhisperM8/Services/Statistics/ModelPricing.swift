import Foundation

/// API-Preise je Million Token in US-Dollar. Grundlage für den „API-Gegenwert“:
/// was dieselben Token über die API gekostet hätten. Mit Abo zahlt der Nutzer
/// das nicht.
///
/// Quellen (abgerufen am 5. November 2026, Standard-Stufe, kurzer Kontext):
/// - Anthropic: https://platform.claude.com/docs/en/about-claude/pricing
///   („Model pricing“ und „Fast mode pricing“)
/// - OpenAI: https://developers.openai.com/api/docs/pricing
///   („Standard“ und „Fast tier“)
///
/// Nur Modelle mit offiziellem Preis stehen in der Tabelle. Alles andere
/// bleibt ohne Gegenwert, statt über ein Präfix bei einem verwandten Modell zu
/// landen (früher fiel `claude-opus-4-8` auf den Opus-4.0-Preis und
/// `gpt-5.4-mini` auf den von `gpt-5`).
///
/// Bewusst nicht abgebildet: Aufschläge für Prompts über 272k (OpenAI) bzw.
/// 100k (Haiku 5.5), bezahltes Cache-Schreiben bei gpt-6/gpt-5.6, der
/// US-Inference-Aufschlag und Aktionspreise. Der Gegenwert ist eine
/// Größenordnung, keine Rechnung.
struct ModelPrice: Equatable, Sendable {
    var input: Double
    var cacheWrite5m: Double
    var cacheWrite1h: Double
    var cacheRead: Double
    var output: Double

    /// Kosten in USD für einen Verbrauch.
    func cost(of usage: TokenUsage) -> Double {
        let perToken = 1.0 / 1_000_000
        return (Double(usage.input) * input
            + Double(usage.cacheWrite5m) * cacheWrite5m
            + Double(usage.cacheWrite1h) * cacheWrite1h
            + Double(usage.cacheRead) * cacheRead
            + Double(usage.output) * output) * perToken
    }

    /// Anthropic-Schema: Cache schreiben 1,25× (5 min) bzw. 2× (1 h) Eingabe.
    static func anthropic(input: Double, cacheRead: Double, output: Double) -> ModelPrice {
        ModelPrice(input: input, cacheWrite5m: input * 1.25, cacheWrite1h: input * 2, cacheRead: cacheRead, output: output)
    }

    /// OpenAI kennt kein bezahltes Cache-Schreiben.
    static func openAI(input: Double, cachedInput: Double, output: Double) -> ModelPrice {
        ModelPrice(input: input, cacheWrite5m: input, cacheWrite1h: input, cacheRead: cachedInput, output: output)
    }

    func scaled(_ factor: Double) -> ModelPrice {
        ModelPrice(
            input: input * factor,
            cacheWrite5m: cacheWrite5m * factor,
            cacheWrite1h: cacheWrite1h * factor,
            cacheRead: cacheRead * factor,
            output: output * factor
        )
    }
}

enum ModelPricing {
    /// Suffix, den die Protokoll-Leser an das Modell hängen, wenn Claude Code
    /// im Fast-Modus lief (`usage.speed == "fast"`).
    static let fastSuffix = "-fast"

    /// Modell-ID (ohne Datum, Fast-Endung, Proxy-Präfix und `[1m]`) → Preis.
    /// Exakte Treffer statt Präfixen: `claude-opus-5` darf nicht für
    /// `claude-opus-5-5` gelten, `gpt-5` nicht für `gpt-5.4-mini`.
    private static let table: [String: ModelPrice] = {
        var table: [String: ModelPrice] = [:]
        func add(_ ids: [String], _ price: ModelPrice) {
            for id in ids { table[id] = price }
        }
        // Anthropic. Cache-Lesen laut Tabelle: 0,025× bei Fable 5.1, 0,05× bei
        // Opus/Sonnet 5.5, sonst 0,1×.
        add(["claude-fable-5-1", "claude-mythos-5-1"], .anthropic(input: 10, cacheRead: 0.25, output: 50))
        add(["claude-fable-5", "claude-mythos-5"], .anthropic(input: 10, cacheRead: 1, output: 50))
        add(["claude-opus-5-5"], .anthropic(input: 4, cacheRead: 0.20, output: 20))
        add(["claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5"],
            .anthropic(input: 5, cacheRead: 0.50, output: 25))
        add(["claude-opus-4-1", "claude-opus-4", "claude-opus-4-0"], .anthropic(input: 15, cacheRead: 1.50, output: 75))
        add(["claude-sonnet-5-5"], .anthropic(input: 2, cacheRead: 0.10, output: 10))
        add(["claude-sonnet-5"], .anthropic(input: 2, cacheRead: 0.20, output: 10))
        add(["claude-sonnet-4-6", "claude-sonnet-4-5", "claude-sonnet-4", "claude-sonnet-4-0"],
            .anthropic(input: 3, cacheRead: 0.30, output: 15))
        add(["claude-haiku-5-5"], .anthropic(input: 0.10, cacheRead: 0.01, output: 0.50))
        add(["claude-haiku-4-5"], .anthropic(input: 1, cacheRead: 0.10, output: 5))
        add(["claude-3-5-haiku"], .anthropic(input: 0.80, cacheRead: 0.08, output: 4))
        // OpenAI
        add(["gpt-6-astra", "gpt-6-astra-law"], .openAI(input: 10, cachedInput: 1, output: 50))
        add(["gpt-6.1-sol"], .openAI(input: 2, cachedInput: 0.10, output: 10))
        add(["gpt-6.1-terra"], .openAI(input: 1, cachedInput: 0.05, output: 5))
        add(["gpt-6-sol"], .openAI(input: 2, cachedInput: 0.20, output: 10))
        add(["gpt-6-luna"], .openAI(input: 0.10, cachedInput: 0.01, output: 0.50))
        add(["gpt-5.6-sol"], .openAI(input: 4, cachedInput: 0.40, output: 20))
        add(["gpt-5.6-terra"], .openAI(input: 2, cachedInput: 0.20, output: 12))
        add(["gpt-5.6-luna"], .openAI(input: 0.20, cachedInput: 0.02, output: 1.20))
        add(["gpt-5.5"], .openAI(input: 5, cachedInput: 0.50, output: 30))
        add(["gpt-5.4"], .openAI(input: 2.50, cachedInput: 0.25, output: 15))
        add(["gpt-5.4-mini"], .openAI(input: 0.75, cachedInput: 0.075, output: 4.50))
        add(["gpt-5.4-nano"], .openAI(input: 0.20, cachedInput: 0.02, output: 1.25))
        add(["gpt-5.3-codex", "gpt-5.2"], .openAI(input: 1.75, cachedInput: 0.175, output: 14))
        add(["gpt-5.1", "gpt-5"], .openAI(input: 1.25, cachedInput: 0.125, output: 10))
        add(["gpt-5-mini"], .openAI(input: 0.25, cachedInput: 0.025, output: 2))
        add(["gpt-5-nano"], .openAI(input: 0.05, cachedInput: 0.005, output: 0.40))
        add(["o3"], .openAI(input: 2, cachedInput: 0.50, output: 8))
        return table
    }()

    /// Fast-Modus als Faktor auf den Standardpreis, nur wo die Listen ihn
    /// führen; sonst bleibt ein `-fast`-Modell ohne Preis. Anthropic: Opus 5.5
    /// 8 $/40 $, Opus 5 und 4.8 10 $/50 $. OpenAI „Fast tier“ (früher Priority):
    /// meist das Doppelte, gpt-5.5 12,50 $/75 $, gpt-5-mini 0,45 $/3,60 $,
    /// o3 3,50 $/14 $.
    private static let fastFactor: [String: Double] = {
        var factors: [String: Double] = [:]
        for id in [
            "claude-opus-5-5", "claude-opus-5", "claude-opus-4-8",
            "gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-sol", "gpt-6-luna",
            "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.4", "gpt-5.4-mini",
            "gpt-5.3-codex", "gpt-5.2", "gpt-5.1", "gpt-5",
        ] { factors[id] = 2 }
        factors["gpt-5.5"] = 2.5
        factors["gpt-5-mini"] = 1.8
        factors["o3"] = 1.75
        return factors
    }()

    /// Kanonische Modell-ID für die Preistabelle: klein, ohne Proxy-Präfix,
    /// ohne Kontext-Markierung (`[1m]`) und ohne Datums-Snapshot
    /// (`-20251001`, `-2025-08-07`). Liefert auch, ob es der Fast-Modus war.
    static func canonicalID(for model: String) -> (id: String, fast: Bool) {
        var name = model.lowercased().trimmingCharacters(in: .whitespaces)
        var fast = false
        if name.hasSuffix(fastSuffix) {
            fast = true
            name.removeLast(fastSuffix.count)
        }
        // Proxy-Präfixe wie `openai/gpt-6.1-sol` abschneiden.
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        if let bracket = name.firstIndex(of: "[") {
            name = String(name[..<bracket])
        }
        var parts = name.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        // Anthropic: `-20251001`.
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            parts.removeLast()
        } else if parts.count >= 4,
                  parts[parts.count - 3].count == 4, parts[parts.count - 3].allSatisfy(\.isNumber),
                  parts[parts.count - 2].count == 2, parts[parts.count - 2].allSatisfy(\.isNumber),
                  parts[parts.count - 1].count == 2, parts[parts.count - 1].allSatisfy(\.isNumber) {
            // OpenAI: `-2025-08-07`.
            parts.removeLast(3)
        }
        return (parts.joined(separator: "-"), fast)
    }

    /// Preis für ein Modell, `nil` für unbekannte Modelle (die Seite zeigt sie
    /// dann ohne Gegenwert an, statt zu raten).
    static func price(for model: String) -> ModelPrice? {
        let (id, fast) = canonicalID(for: model)
        guard let price = table[id] else { return nil }
        guard fast else { return price }
        return fastFactor[id].map { price.scaled($0) }
    }

    static func costUSD(model: String, usage: TokenUsage) -> Double? {
        price(for: model)?.cost(of: usage)
    }

    /// Lesbarer Name für die Tabelle: `claude-opus-5-5` → „Opus 5.5“.
    static func displayName(for model: String) -> String {
        var name = model
        var suffix = ""
        if name.hasSuffix(fastSuffix) {
            name.removeLast(fastSuffix.count)
            suffix = " (Fast)"
        }
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        let lower = name.lowercased()
        if lower.hasPrefix("claude-") {
            // claude-opus-5-5[-20261001] → Opus 5.5
            var parts = lower.dropFirst("claude-".count).split(separator: "-").map(String.init)
            // Datums-Suffix (8 Ziffern) weg.
            if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
            if let family = parts.first, family.first?.isLetter == true {
                let version = parts.dropFirst().joined(separator: ".")
                return capitalized(family) + (version.isEmpty ? "" : " \(version)") + suffix
            }
            // Alte Schreibweise: claude-3-5-haiku
            if let family = parts.last {
                let version = parts.dropLast().joined(separator: ".")
                return capitalized(family) + " \(version)" + suffix
            }
        }
        if lower.hasPrefix("gpt-") {
            // gpt-6.1-sol → GPT 6.1 Sol
            let parts = name.dropFirst("gpt-".count).split(separator: "-").map(String.init)
            let rest = parts.map { $0.first?.isLetter == true ? capitalized($0) : $0 }
            return "GPT " + rest.joined(separator: " ") + suffix
        }
        return name + suffix
    }

    private static func capitalized(_ word: String) -> String {
        word.prefix(1).uppercased() + String(word.dropFirst())
    }

    /// Läuft das Modell über ein ChatGPT-Abo (GPT im Proxy oder Codex)?
    static func isOpenAIModel(_ model: String) -> Bool {
        var name = model.lowercased()
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        return name.hasPrefix("gpt-") || name.hasPrefix("o3") || name.hasPrefix("o4") || name.hasPrefix("codex")
    }
}
