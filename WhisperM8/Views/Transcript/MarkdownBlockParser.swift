import Foundation

/// Block-Element eines leichtgewichtig geparsten Markdown-Texts. Inline-
/// Formatierung (fett, `code`, Links) bleibt im String und wird erst in der
/// View via `AttributedString(markdown:)` aufgelöst.
enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case codeFence(language: String?, code: String)
    case list(items: [String], ordered: Bool)
    case quote(String)
    /// Markdown-Tabellen behalten wir als Monospace-Block — echtes
    /// Tabellen-Layout lohnt den Aufwand hier nicht, Ausrichtung bleibt lesbar.
    case table(String)
    case divider
}

/// Purer, zeilenbasierter Markdown-Block-Splitter für Assistant-Antworten.
/// Bewusst KEIN vollständiger Markdown-Parser: Code-Fences, Überschriften,
/// Listen, Quotes, Tabellen und Absätze reichen für Agent-Antworten — alles
/// andere fällt tolerant auf Absätze zurück (nie throwen, nie Inhalt
/// verlieren).
enum MarkdownBlockParser {

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var listItems: [String] = []
        var listOrdered = false
        var quoteLines: [String] = []
        var tableLines: [String] = []
        var fenceLines: [String] = []
        var fenceLanguage: String?
        var inFence = false

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
            paragraphLines.removeAll()
        }
        func flushList() {
            guard !listItems.isEmpty else { return }
            blocks.append(.list(items: listItems, ordered: listOrdered))
            listItems.removeAll()
        }
        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            blocks.append(.quote(quoteLines.joined(separator: "\n")))
            quoteLines.removeAll()
        }
        func flushTable() {
            guard !tableLines.isEmpty else { return }
            blocks.append(.table(tableLines.joined(separator: "\n")))
            tableLines.removeAll()
        }
        func flushAll() {
            flushParagraph(); flushList(); flushQuote(); flushTable()
        }

        for rawLine in text.components(separatedBy: "\n") {
            if inFence {
                if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    blocks.append(.codeFence(language: fenceLanguage, code: fenceLines.joined(separator: "\n")))
                    fenceLines.removeAll()
                    fenceLanguage = nil
                    inFence = false
                } else {
                    fenceLines.append(rawLine)
                }
                continue
            }

            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushAll()
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                fenceLanguage = lang.isEmpty ? nil : lang
                inFence = true
                continue
            }
            if trimmed.isEmpty {
                flushAll()
                continue
            }
            if let heading = parseHeading(trimmed) {
                flushAll()
                blocks.append(heading)
                continue
            }
            if isDivider(trimmed) {
                flushAll()
                blocks.append(.divider)
                continue
            }
            if trimmed.hasPrefix("|") {
                flushParagraph(); flushList(); flushQuote()
                tableLines.append(trimmed)
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph(); flushList(); flushTable()
                quoteLines.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if let (item, ordered) = parseListItem(rawLine) {
                flushParagraph(); flushQuote(); flushTable()
                if !listItems.isEmpty && ordered != listOrdered { flushList() }
                listOrdered = ordered
                listItems.append(item)
                continue
            }
            // Fortsetzungszeile eines Listen-Items (eingerückt, kein Marker).
            if !listItems.isEmpty, rawLine.hasPrefix("  ") {
                listItems[listItems.count - 1] += "\n" + trimmed
                continue
            }
            flushList(); flushQuote(); flushTable()
            paragraphLines.append(rawLine)
        }

        if inFence {
            // Unabgeschlossener Fence (z.B. Live-Stream mitten im Codeblock) —
            // Inhalt trotzdem als Code zeigen, nichts verlieren.
            blocks.append(.codeFence(language: fenceLanguage, code: fenceLines.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    // MARK: - Zeilen-Klassifikation

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        guard line.hasPrefix("#") else { return nil }
        let level = line.prefix(while: { $0 == "#" }).count
        guard level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isDivider(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        let set = Set(line)
        return set == ["-"] || set == ["*"] || set == ["_"]
    }

    /// `- item` / `* item` / `+ item` / `1. item` / `1) item`.
    private static func parseListItem(_ rawLine: String) -> (String, ordered: Bool)? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ "] {
            if trimmed.hasPrefix(marker) {
                return (String(trimmed.dropFirst(2)), ordered: false)
            }
        }
        let digits = trimmed.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3 {
            let afterDigits = trimmed.dropFirst(digits.count)
            if afterDigits.hasPrefix(". ") || afterDigits.hasPrefix(") ") {
                return (String(afterDigits.dropFirst(2)), ordered: true)
            }
        }
        return nil
    }
}
