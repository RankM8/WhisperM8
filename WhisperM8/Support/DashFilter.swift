import Foundation

/// Entfernt Gedankenstriche (— und –) aus diktierten Texten. Sie lassen Texte
/// sofort nach KI aussehen; der Prompt verbietet sie zwar, Modelle setzen sie
/// aber trotzdem. Dieser Filter ist das Sicherheitsnetz danach.
///
/// Ersetzt wird je nach Stellung: Aufzählungszeichen am Zeilenanfang werden
/// zu "-", Zahlenbereiche zu "10-12", ein Strich vor Satzzeichen oder am
/// Zeilenende fällt weg, alles andere wird zum Komma. Code (Fences mit ```
/// und Inline-Code in Backticks) bleibt unangetastet.
enum DashFilter {
    static func apply(_ text: String) -> String {
        guard text.contains("\u{2014}") || text.contains("\u{2013}") else { return text }

        var insideFence = false
        let lines = text.components(separatedBy: "\n").map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                insideFence.toggle()
                return line
            }
            return insideFence ? line : filterLine(line)
        }
        return lines.joined(separator: "\n")
    }

    private static func filterLine(_ line: String) -> String {
        // Aufzählungszeichen nur am Zeilenanfang, also vor der Backtick-Teilung.
        var line = replace(#"^(\s*)[—–]+\s+"#, in: line, with: "$1- ")
        line = replace(#"^(\s*)[—–]+"#, in: line, with: "$1")

        // Gerade Teile liegen außerhalb von Inline-Code, ungerade innerhalb.
        let parts = line.components(separatedBy: "`")
        return parts.enumerated()
            .map { index, part in
                index.isMultiple(of: 2) ? filterProse(part, endsLine: index == parts.count - 1) : part
            }
            .joined(separator: "`")
    }

    private static func filterProse(_ text: String, endsLine: Bool) -> String {
        var text = text
        // 10–12, 2025 — 2026 → Bindestrich
        text = replace(#"(\d)\s*[—–]\s*(?=\d)"#, in: text, with: "$1-")
        // Ost–West (ohne Leerzeichen, nur Halbgeviertstrich) → Bindestrich
        text = replace(#"(?<=\p{L})–(?=\p{L})"#, in: text, with: "-")
        // Strich vor Satzzeichen fällt weg: "gut —." → "gut."
        text = replace(#"\s*[—–]+\s*(?=[.,;:!?)\]])"#, in: text, with: "")
        // Strich am Zeilenende fällt weg
        if endsLine {
            text = replace(#"\s*[—–]+\s*$"#, in: text, with: "")
        }
        // Satzzeichen davor bleibt allein stehen: ", — " → ", ", "(— x" → "(x"
        text = replace(#"([,;:])\s*[—–]+\s*"#, in: text, with: "$1 ")
        text = replace(#"\(\s*[—–]+\s*"#, in: text, with: "(")
        // Rest: Einschub- oder Gedankenstrich → Komma
        text = replace(#"\s*[—–]+\s*"#, in: text, with: ", ")
        return text
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
