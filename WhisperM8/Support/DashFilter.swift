import Foundation

/// Entfernt Gedankenstriche (— und –) aus diktierten Texten. Sie lassen Texte
/// sofort nach KI aussehen; der Prompt verbietet sie zwar, Modelle setzen sie
/// aber trotzdem. Dieser Filter ist das Sicherheitsnetz danach.
///
/// Ersetzt wird je nach Stellung: Aufzählungszeichen am Zeilenanfang werden
/// zu "-" (nur in einer Liste, siehe `isListBullet`), ein Strich am
/// Satzanfang fällt weg, Zahlenbereiche werden zu "10-12", ein Strich vor
/// Satzzeichen oder am Zeilenende fällt weg, alles andere wird zum Komma.
///
/// Stehen bleiben Striche, die kein Gedankenstrich sind: Minus vor einer
/// Ziffer („–5 °C“), der Preisstrich („49,–“), Platzhalter in Tabellenzellen
/// („| — |“) und Code (Fences mit ``` oder ~~~, eingerückte Codeblöcke,
/// Inline-Code in Backticks).
enum DashFilter {
    static func containsDash(_ text: String) -> Bool {
        text.contains("\u{2014}") || text.contains("\u{2013}")
    }

    static func apply(_ text: String) -> String {
        guard containsDash(text) else { return text }

        let lines = text.components(separatedBy: "\n")
        var output: [String] = []
        output.reserveCapacity(lines.count)
        var fence: String?
        var insideIndentedCode = false
        var previousBlank = true

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { previousBlank = trimmed.isEmpty }

            if let marker = fenceMarker(trimmed) {
                if fence == nil {
                    fence = marker
                } else if fence == marker {
                    fence = nil
                }
                output.append(line)
                continue
            }
            if fence != nil {
                output.append(line)
                continue
            }
            if trimmed.isEmpty {
                output.append(line)
                continue
            }
            // Eingerückter Codeblock (Markdown): beginnt nach einer Leerzeile
            // und läuft, solange die Zeilen eingerückt bleiben. Eingerückte
            // Listenpunkte sind kein Code.
            if isIndented(line), !isListItem(trimmed), insideIndentedCode || previousBlank {
                insideIndentedCode = true
                output.append(line)
                continue
            }
            insideIndentedCode = false
            output.append(filterLine(line, isListBullet: isListBullet(at: index, in: lines)))
        }
        return output.joined(separator: "\n")
    }

    // MARK: - Zeilen

    private static func filterLine(_ line: String, isListBullet: Bool) -> String {
        var line = protectNonProseDashes(line)
        // Aufzählungszeichen nur am Zeilenanfang, also vor der Backtick-Teilung.
        if isListBullet {
            line = replace(#"^(\s*)[—–]+\s+"#, in: line, with: "$1- ")
        }
        // Satzanfang mit Strich (kein Listenpunkt): Strich fällt weg.
        line = replace(#"^(\s*)[—–]+\s*"#, in: line, with: "$1")

        // Gerade Teile liegen außerhalb von Inline-Code, ungerade innerhalb.
        let parts = line.components(separatedBy: "`")
        let filtered = parts.enumerated()
            .map { index, part in
                index.isMultiple(of: 2) ? filterProse(part, endsLine: index == parts.count - 1) : part
            }
            .joined(separator: "`")
        return restoreProtectedDashes(filtered)
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

    // MARK: - Geschützte Striche

    /// Platzhalter aus dem Private-Use-Bereich, die keine der Regeln anfasst.
    private static let protectedEnDash: Character = "\u{E000}"
    private static let protectedEmDash: Character = "\u{E001}"

    /// Ersetzt Striche, die keine Gedankenstriche sind, durch Platzhalter.
    /// Inline-Code wird mit erfasst, das ist harmlos: `restore` stellt alles
    /// wieder her.
    private static func protectNonProseDashes(_ line: String) -> String {
        var line = line
        // Minus: Halbgeviertstrich direkt vor einer Ziffer, ohne Zahl davor
        // („–5 °C“, „Temperatur –5 Grad“). Mit Zahl davor ist es ein Bereich.
        line = protect(#"(?:^|[^\d\s])\s*(–)(?=\d)"#, in: line)
        // Preis: „49,–“, „49.–“
        line = protect(#"\d[,.]([—–])"#, in: line)
        // Tabellenzelle, die nur aus Strichen besteht: „| — |“
        line = protect(#"\|[ \t]*([—–]+)[ \t]*(?=\||$)"#, in: line)
        return line
    }

    private static func protect(_ pattern: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return text
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        let result = NSMutableString(string: nsText)
        for match in matches.reversed() {
            let range = match.range(at: 1)
            guard range.location != NSNotFound else { continue }
            let dashes = nsText.substring(with: range)
            let placeholders = String(dashes.map { $0 == "\u{2014}" ? protectedEmDash : protectedEnDash })
            result.replaceCharacters(in: range, with: placeholders)
        }
        return result as String
    }

    private static func restoreProtectedDashes(_ text: String) -> String {
        text
            .replacingOccurrences(of: String(protectedEnDash), with: "\u{2013}")
            .replacingOccurrences(of: String(protectedEmDash), with: "\u{2014}")
    }

    // MARK: - Zeilenarten

    /// ``` oder ~~~ öffnet bzw. schließt einen Codeblock (gleiches Zeichen).
    private static func fenceMarker(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func isIndented(_ line: String) -> Bool {
        line.hasPrefix("    ") || line.hasPrefix("\t")
    }

    /// Zeile, die wie ein Listenpunkt beginnt (-, *, +, •, —, –, „1.“, „1)“).
    private static func isListItem(_ trimmed: String) -> Bool {
        trimmed.range(of: #"^([-*+•]|[—–]+|\d+[.)])\s+\S"#, options: .regularExpression) != nil
    }

    /// Ein Strich am Zeilenanfang ist nur dann ein Aufzählungszeichen, wenn
    /// die Zeile in einer Liste steht: Nachbarzeile ist ebenfalls ein
    /// Listenpunkt oder die Zeile davor endet mit Doppelpunkt. Sonst beginnt
    /// dort ein Satz mit Gedankenstrich, und der Strich fällt weg.
    private static func isListBullet(at index: Int, in lines: [String]) -> Bool {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: #"^[—–]+\s+\S"#, options: .regularExpression) != nil else { return false }
        let previous = neighbor(of: index, step: -1, in: lines)
        let next = neighbor(of: index, step: 1, in: lines)
        if let previous, isListItem(previous) || previous.hasSuffix(":") { return true }
        if let next, isListItem(next) { return true }
        return false
    }

    /// Nächste nicht leere Zeile in Richtung `step` (getrimmt).
    private static func neighbor(of index: Int, step: Int, in lines: [String]) -> String? {
        var cursor = index + step
        while cursor >= 0, cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
            cursor += step
        }
        return nil
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
