import Foundation

// MARK: - Beschreibung eines Tickets, leicht gesetzt

/// Ein Stück der Beschreibung. Tickets sind Markdown; gezeigt wird das, was in
/// Tickets vorkommt: Überschriften, Kästchen, Listenpunkte und Absätze mit
/// Fettschrift, Code und Links. Alles andere bleibt als Text stehen.
enum TicketDescriptionBlock: Equatable {
    case heading(String)
    case check(done: Bool, text: AttributedString)
    case bullet(AttributedString)
    /// Punkt einer nummerierten Liste mit seiner Nummer („3.“).
    case numbered(String, AttributedString)
    case text(AttributedString)
    /// Zeile eines Codeblocks, unverändert.
    case code(String)
    case gap
    /// Die Beschreibung war länger; der Rest steht im Ticket-Werkzeug.
    case truncated
}

enum TicketDescriptionBlocks {
    /// Zerlegt die Beschreibung. Pur; gerechnet wird beim Wählen eines Tickets,
    /// nicht beim Zeichnen.
    /// Mehr Blöcke werden nicht gesetzt: Jede Zeile ist ein eigenes Stück Ansicht.
    static let maxBlocks = 400

    static func make(_ description: String) -> [TicketDescriptionBlock] {
        var blocks: [TicketDescriptionBlock] = []
        var fence: String?
        for raw in description.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if blocks.count >= maxBlocks {
                blocks.append(.truncated)
                return blocks
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if line.hasPrefix(open) { fence = nil } else { blocks.append(.code(raw)) }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fence = String(line.prefix(3))
                continue
            }
            if line == "+++" {
                // Ende eines einklappbaren Abschnitts: kein Inhalt.
                continue
            }
            if line.isEmpty {
                if blocks.last != .gap, !blocks.isEmpty { blocks.append(.gap) }
            } else if let title = heading(line) {
                blocks.append(.heading(title))
            } else if let box = checkbox(line) {
                blocks.append(.check(done: box.done, text: inline(box.text)))
            } else if let item = numbered(line) {
                blocks.append(.numbered(item.number, inline(item.text)))
            } else if let item = bullet(line) {
                blocks.append(.bullet(inline(item)))
            } else {
                blocks.append(.text(inline(line)))
            }
        }
        while blocks.last == .gap { blocks.removeLast() }
        return blocks
    }

    private static func heading(_ line: String) -> String? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level), line.dropFirst(level).first == " " else {
            // Linears einklappbare Abschnitte: `+++ Titel` öffnet, `+++` schließt.
            if line.hasPrefix("+++") {
                let title = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? nil : title
            }
            return nil
        }
        return line.dropFirst(level).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "")
    }

    private static func checkbox(_ line: String) -> (done: Bool, text: String)? {
        guard let match = line.range(of: #"^[-*+]\s+\[([ xX])\]\s+"#, options: .regularExpression),
              let open = line[match].firstIndex(of: "[") else { return nil }
        return (line[line.index(after: open)] != " ", String(line[match.upperBound...]))
    }

    private static func bullet(_ line: String) -> String? {
        guard let match = line.range(of: #"^[-*+]\s+"#, options: .regularExpression) else { return nil }
        return String(line[match.upperBound...])
    }

    private static func numbered(_ line: String) -> (number: String, text: String)? {
        guard let match = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) else { return nil }
        return (line[match].trimmingCharacters(in: .whitespaces), String(line[match.upperBound...]))
    }

    /// Fettschrift, Code und Links innerhalb einer Zeile. Tickets stammen auch
    /// von anderen: Ein Link bleibt nur anklickbar, wenn er ins Web führt.
    /// Alles andere (`file:`, `smb:`, Schemata fremder Apps) wird zu Text.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let text = withoutImages(text)
        var result = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for run in result.runs {
            guard let link = run.link, !isSafe(link) else { continue }
            result[run.range].link = nil
        }
        return result
    }

    /// Bilder (`![Alt](Adresse)`) werden zum Verweis „Bild in Linear“. Ihre
    /// Adressen bei Linear verfallen nach Minuten und brauchen eine Anmeldung;
    /// geladen wird von hier nichts.
    static func withoutImages(_ text: String) -> String {
        guard text.contains("![") else { return text }
        let placeholder = "[" + String(localized: "Image in Linear") + "]"
        return text.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: placeholder, options: .regularExpression)
    }

    static func isSafe(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "https" || scheme == "http") && url.host != nil
    }
}
