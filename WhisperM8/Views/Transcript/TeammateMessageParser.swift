import Foundation

/// Erkannte Teammate-/System-Injektion in einer User-Message (z.B.
/// `<teammate-message …>`-Blöcke, die Claude Code von Peer-Sessions
/// einspeist). Die Timeline rendert sie als kompakten Block mit Gist statt
/// als bildschirmfüllende Prompt-Bubble.
struct InjectedTeammateMessage: Equatable {
    var teammateID: String?
    /// Nachrichten-Typ aus dem Payload, z.B. `idle_notification`.
    var kind: String?
    var summary: String?
    /// Kompletter Original-Text — bleibt aufklappbar erhalten (verlustfrei).
    var raw: String

    /// Ein-Zeilen-Zusammenfassung für die eingeklappte Kopfzeile.
    var gist: String {
        var parts: [String] = []
        if let teammateID, !teammateID.isEmpty { parts.append(teammateID) }
        if let kind, !kind.isEmpty { parts.append(kind) }
        let head = parts.joined(separator: " · ")
        if let summary, !summary.isEmpty {
            return head.isEmpty ? "„\(summary)\"" : "\(head) — „\(summary)\""
        }
        if !head.isEmpty { return head }
        let firstLine = raw.split(separator: "\n").first.map(String.init) ?? raw
        return String(firstLine.prefix(90))
    }
}

/// Purer Detektor für injizierte Teammate-Nachrichten. Tolerant: fehlende
/// Felder ergeben nil-Attribute, nie einen Ausfall — im Zweifel bleibt der
/// Prompt eine normale Bubble (`parse` liefert nil).
enum TeammateMessageParser {

    static func parse(_ text: String) -> InjectedTeammateMessage? {
        guard text.contains("<teammate-message") else { return nil }
        return InjectedTeammateMessage(
            teammateID: firstMatch(in: text, pattern: #"teammate_id="([^"]*)""#),
            kind: firstMatch(in: text, pattern: #""type"\s*:\s*"([^"]*)""#),
            summary: firstMatch(in: text, pattern: #""summary"\s*:\s*"((?:[^"\\]|\\.)*)""#)
                .map(unescapeJSONString),
            raw: text
        )
    }

    // MARK: - Intern

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let value = String(text[range])
        return value.isEmpty ? nil : value
    }

    /// Minimales Unescaping der häufigen JSON-Sequenzen im Summary-Feld.
    private static func unescapeJSONString(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
