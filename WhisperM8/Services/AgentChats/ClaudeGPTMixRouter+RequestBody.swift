import Foundation

/// Request-Body-Auswertung des Mix-Routers (LR-GPT-008): `model` einmal per
/// Byte-Scan ermitteln statt den Body drei- bis viermal vollständig zu parsen.
/// Bei Bodies von mehreren MB Kontext war das der dominante Router-Posten.
extension ClaudeGPTMixRouter {
    /// Zähler für volle JSON-Parses von Request-Bodies (Tests/Messung).
    static let bodyParseCounter = BodyParseCounter()

    final class BodyParseCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }
    }

    /// Einziger Ort, der einen Request-Body voll parst (zählt mit).
    static func parseBody(_ body: Data) -> Any? {
        bodyParseCounter.increment()
        return try? JSONSerialization.jsonObject(with: body)
    }

    enum ModelScan: Equatable {
        case found(String)
        case absent
        case unsure
    }

    /// Liest den String-Wert des Schlüssels `model` auf Ebene 1 ohne JSON-Parse.
    /// Strings werden übersprungen (Escapes beachtet), die Klammertiefe wird
    /// mitgeführt; bei doppeltem Schlüssel gilt wie im Parser der erste.
    /// `.unsure` (keine `{`-Wurzel, Escapes im Schlüssel/Wert, unbalanciert)
    /// schickt den Aufrufer auf den vollen Parse.
    static func scanTopLevelModel(in body: Data) -> ModelScan {
        body.withUnsafeBytes { raw -> ModelScan in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            let quote = UInt8(ascii: "\"")
            let backslash = UInt8(ascii: "\\")
            var index = 0

            func skipWhitespace() {
                while index < count,
                      bytes[index] == 0x20 || bytes[index] == 0x0A || bytes[index] == 0x0D || bytes[index] == 0x09 {
                    index += 1
                }
            }

            skipWhitespace()
            guard index < count, bytes[index] == UInt8(ascii: "{") else { return .unsure }
            let modelKey = Array("model".utf8)
            var depth = 0
            var expectingKey = false
            var found: String?
            var sawModelKey = false

            while index < count {
                let byte = bytes[index]
                switch byte {
                case quote:
                    let start = index + 1
                    index = start
                    var hasEscape = false
                    while index < count, bytes[index] != quote {
                        if bytes[index] == backslash {
                            hasEscape = true
                            index += 1
                        }
                        index += 1
                    }
                    guard index < count else { return .unsure }
                    let end = index
                    index += 1
                    guard depth == 1, expectingKey else { continue }
                    expectingKey = false
                    if hasEscape { return .unsure }
                    let isModelKey = (end - start) == modelKey.count
                        && modelKey.indices.allSatisfy { bytes[start + $0] == modelKey[$0] }
                    // Doppelter Schlüssel: der Parser behält den ERSTEN Wert.
                    guard isModelKey, !sawModelKey else { continue }
                    sawModelKey = true
                    skipWhitespace()
                    guard index < count, bytes[index] == UInt8(ascii: ":") else { return .unsure }
                    index += 1
                    skipWhitespace()
                    guard index < count else { return .unsure }
                    if bytes[index] == quote {
                        let valueStart = index + 1
                        var cursor = valueStart
                        while cursor < count, bytes[cursor] != quote {
                            if bytes[cursor] == backslash { return .unsure }
                            cursor += 1
                        }
                        guard cursor < count else { return .unsure }
                        let slice = UnsafeBufferPointer(rebasing: bytes[valueStart..<cursor])
                        guard let value = String(bytes: slice, encoding: .utf8) else { return .unsure }
                        found = value
                        index = cursor + 1
                    } else {
                        // Kein String-Wert: der Parser lieferte `nil`.
                        found = nil
                    }
                case UInt8(ascii: "{"):
                    depth += 1
                    if depth == 1 { expectingKey = true }
                    index += 1
                case UInt8(ascii: "["):
                    depth += 1
                    index += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth < 0 { return .unsure }
                    index += 1
                case UInt8(ascii: ","):
                    if depth == 1 { expectingKey = true }
                    index += 1
                default:
                    index += 1
                }
            }
            guard depth == 0 else { return .unsure }
            return found.map(ModelScan.found) ?? .absent
        }
    }

    /// Kanonischer Frontier-Alias, wenn `model` ein Auto-Alias ist (`auto`,
    /// `gpt-auto`, optional `-fast`, `[1m]`); sonst `nil`.
    static func resolvedAutoModel(for model: String?) -> String? {
        guard let model else { return nil }
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let stripped = normalized.hasSuffix("[1m]") ? String(normalized.dropLast(4)) : normalized
        let base = stripped.hasSuffix("-fast") ? String(stripped.dropLast("-fast".count)) : stripped
        guard ClaudeGPTModelAlias.isAutoModel(base) else { return nil }
        return ClaudeGPTModelAlias.canonicalGPTModel(stripped)
    }

    /// Wie `resolvingAutoModel(in:)`, mit bereits ermitteltem `model` (kein
    /// zweiter Scan). Liefert zusätzlich das aufgelöste Modell (`nil` = Body
    /// unverändert).
    static func resolvingAutoModel(in body: Data, requestedModel model: String?) -> (body: Data, resolved: String?) {
        guard let model, let resolved = resolvedAutoModel(for: model),
              let object = parseBody(body),
              var dictionary = object as? [String: Any] else {
            return (body, nil)
        }
        dictionary["model"] = resolved
        guard let rewritten = try? JSONSerialization.data(withJSONObject: dictionary) else {
            return (body, nil)
        }
        Logger.claudeGPTRouter.info(
            "gpt_auto_model_resolved requested=\(model, privacy: .public) resolved=\(resolved, privacy: .public)"
        )
        return (rewritten, resolved)
    }

    struct PreparedRequestBody {
        var body: Data
        var model: String?
        var upstream: Upstream
        /// Nur gesetzt, wenn der Sanitizer tatsächlich Patterns entfernt hat.
        var sanitization: ToolSchemaSanitization?
    }

    /// Request-Body einmal auswerten: `model` per Byte-Scan, Auto-Alias nur bei
    /// Treffer umschreiben, Sanitizer nur für den Codex-Upstream und nur bei
    /// Treffer im Rohtext (vorher 3–4 volle Parses je Request).
    static func prepareRequestBody(_ original: Data) -> PreparedRequestBody {
        var body = original
        var model = model(in: original)
        let auto = resolvingAutoModel(in: original, requestedModel: model)
        if let resolved = auto.resolved {
            body = auto.body
            model = resolved
        }
        let upstream = upstream(forModel: model)
        var sanitization: ToolSchemaSanitization?
        if upstream == .codexProxy {
            let result = sanitizingToolSchemas(in: body)
            if result.removedPatterns > 0 {
                sanitization = result
                body = result.body
            }
        }
        return PreparedRequestBody(body: body, model: model, upstream: upstream, sanitization: sanitization)
    }

    /// Rohtext-Vorfilter für den Sanitizer. Darf nur dann `false` liefern, wenn
    /// im dekodierten Pattern sicher kein `\p{`/`\P{` stehen kann (auch nicht
    /// über `\`/`p`/`P` maskiert).
    static func mayContainUnsupportedPattern(_ body: Data) -> Bool {
        let backslash = "\\"
        let needles: [[UInt8]] = [
            backslash + backslash + "p{",
            backslash + backslash + "P{",
            backslash + "u005c",
            backslash + "u005C",
            backslash + "u0070{",
            backslash + "u0050{",
            // `{` selbst kann maskiert sein: `\\p\u007bCc}` dekodiert zu `\p{Cc}`.
            backslash + "u007b",
            backslash + "u007B",
        ].map { Array($0.utf8) }
        return body.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress, raw.count > 0 else { return false }
            return needles.contains { needle in
                memmem(base, raw.count, needle, needle.count) != nil
            }
        }
    }
}
