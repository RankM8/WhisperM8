import Foundation

/// API-Preise je Million Token in US-Dollar. Grundlage für den „API-Gegenwert“:
/// was dieselben Token über die API gekostet hätten. Mit Abo zahlt der Nutzer
/// das nicht.
///
/// Quellen (Stand November 2026):
/// - https://platform.claude.com/docs/en/about-claude/pricing
/// - https://developers.openai.com/api/docs/pricing
///
/// Bewusst nicht abgebildet: Aufschläge für Prompts über 272k (OpenAI) bzw.
/// 100k (Haiku 5.5) und der US-Inference-Aufschlag. Der Gegenwert ist eine
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

    /// Präfix → Preis. Längere Präfixe zuerst, damit `claude-opus-4-1` nicht
    /// beim Präfix `claude-opus-4` landet.
    private static let table: [(prefix: String, price: ModelPrice)] = [
        // Claude 5
        ("claude-fable-5", .anthropic(input: 10, cacheRead: 0.25, output: 50)),
        ("claude-opus-5", .anthropic(input: 4, cacheRead: 0.20, output: 20)),
        ("claude-sonnet-5", .anthropic(input: 2, cacheRead: 0.10, output: 10)),
        ("claude-haiku-5", .anthropic(input: 0.10, cacheRead: 0.01, output: 0.50)),
        // Claude 4.x
        ("claude-opus-4-5", .anthropic(input: 5, cacheRead: 0.50, output: 25)),
        ("claude-opus-4-1", .anthropic(input: 15, cacheRead: 1.50, output: 75)),
        ("claude-opus-4", .anthropic(input: 15, cacheRead: 1.50, output: 75)),
        ("claude-sonnet-4", .anthropic(input: 3, cacheRead: 0.30, output: 15)),
        ("claude-haiku-4", .anthropic(input: 1, cacheRead: 0.10, output: 5)),
        ("claude-3-5-haiku", .anthropic(input: 0.80, cacheRead: 0.08, output: 4)),
        // OpenAI / Codex
        ("gpt-6.1-terra", .openAI(input: 1, cachedInput: 0.05, output: 5)),
        ("gpt-6.1-sol", .openAI(input: 2, cachedInput: 0.10, output: 10)),
        ("gpt-6.1", .openAI(input: 2, cachedInput: 0.10, output: 10)),
        ("gpt-5.6-sol", .openAI(input: 4, cachedInput: 0.40, output: 20)),
        ("gpt-5.6", .openAI(input: 4, cachedInput: 0.40, output: 20)),
        ("gpt-5", .openAI(input: 1.25, cachedInput: 0.125, output: 10)),
    ].sorted { $0.prefix.count > $1.prefix.count }

    /// Preis für ein Modell, `nil` für unbekannte Modelle (die Seite zeigt sie
    /// dann ohne Gegenwert an, statt zu raten).
    static func price(for model: String) -> ModelPrice? {
        var name = model.lowercased()
        var fast = false
        if name.hasSuffix(fastSuffix) {
            fast = true
            name.removeLast(fastSuffix.count)
        }
        // Proxy-Präfixe wie `openai/gpt-6.1-sol` abschneiden.
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        guard let entry = table.first(where: { name.hasPrefix($0.prefix) }) else { return nil }
        // Fast-Modus: bei Opus 5.5 doppelter Preis (8 $ / 40 $).
        return fast ? entry.price.scaled(2) : entry.price
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
