import Foundation

// MARK: - Geheimnisse in Ausgaben für Agents maskieren

/// Ersetzt typische Geheimnisse (API-Keys, Tokens, private Schlüssel) durch
/// Platzhalter, bevor ein Agent den Text sieht. Reine Logik, kein I/O.
/// Bewusst grob: lieber ein Treffer zu viel als ein Schlüssel im Chat-Verlauf.
enum ClipboardSecretMasker {
    struct Result: Equatable {
        var text: String
        var maskedCount: Int
    }

    private struct Rule {
        let label: String
        let regex: NSRegularExpression
        /// Wenn gesetzt, wird nur diese Capture-Gruppe ersetzt.
        let group: Int?
        let validate: ((String) -> Bool)?
    }

    private static func rule(_ label: String, _ pattern: String, options: NSRegularExpression.Options = [],
                             group: Int? = nil, validate: ((String) -> Bool)? = nil) -> Rule {
        // Muster sind Konstanten; ein Tippfehler fiele sofort im Test auf.
        Rule(label: label, regex: try! NSRegularExpression(pattern: pattern, options: options),
             group: group, validate: validate)
    }

    private static let rules: [Rule] = [
        rule("private-key", #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----|\z)"#),
        rule("jwt", #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*"#),
        rule("github-token", #"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})"#),
        rule("slack-token", #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#),
        rule("aws-key", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        rule("google-key", #"\bAIza[0-9A-Za-z_-]{35}\b"#),
        rule("api-key", #"\bsk-[A-Za-z0-9_-]{20,}"#),
        rule("bearer", #"\b[Bb]earer\s+([A-Za-z0-9._~+/=-]{16,})"#, group: 1),
        // password=…, token: …, api_key = … (Wert ab sechs Zeichen).
        rule("secret", #"(?i)\b(?:password|passwd|passphrase|secret|token|api[_-]?key|access[_-]?key)\b["']?\s*[:=]\s*["']?([^\s"',;]{6,})"#, group: 1),
        // Lange Hex-Ketten (Hashes, Tokens), mindestens 32 Zeichen.
        rule("hex-token", #"(?<![A-Za-z0-9])[A-Fa-f0-9]{32,}(?![A-Za-z0-9])"#),
        // Lange Base64-/URL-safe-Ketten mit Ziffer, Groß- und Kleinbuchstabe.
        rule("token", #"(?<![A-Za-z0-9+_=/.-])[A-Za-z0-9+_=-]{40,}(?![A-Za-z0-9+_=/.-])"#, validate: looksLikeRandomToken),
    ]

    static func looksLikeRandomToken(_ value: String) -> Bool {
        var upper = false, lower = false, digit = false
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A: upper = true
            case 0x61...0x7A: lower = true
            case 0x30...0x39: digit = true
            default: break
            }
        }
        return upper && lower && digit
    }

    static func placeholder(for label: String) -> String { "[REDACTED:\(label)]" }

    static func mask(_ input: String) -> Result {
        var text = input
        var count = 0
        for rule in rules {
            let ns = text as NSString
            let matches = rule.regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            var result = ""
            var cursor = 0
            for match in matches {
                let target = rule.group.map { match.range(at: $0) } ?? match.range
                guard target.location != NSNotFound, target.location >= cursor else { continue }
                let value = ns.substring(with: target)
                if value.hasPrefix("[REDACTED:") { continue }
                if let validate = rule.validate, !validate(value) { continue }
                result += ns.substring(with: NSRange(location: cursor, length: target.location - cursor))
                result += placeholder(for: rule.label)
                cursor = target.location + target.length
                count += 1
            }
            result += ns.substring(from: cursor)
            text = result
        }
        return Result(text: text, maskedCount: count)
    }
}
