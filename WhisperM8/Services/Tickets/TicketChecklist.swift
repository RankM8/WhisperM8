import Foundation

// MARK: - Kästchen unter „Fertig, wenn“

/// Ein Kästchen (`- [ ]` oder `- [x]`) in der Beschreibung eines Tickets.
struct TicketChecklistItem: Equatable {
    /// Laufende Nummer ab 1, so wie `tickets check` sie zeigt.
    var number: Int
    var text: String
    var isDone: Bool
    /// Zeile in der Beschreibung (ab 0).
    var line: Int
}

struct TicketChecklistProgress: Equatable {
    var done: Int
    var total: Int
}

/// Liest und ändert die Kästchen eines Tickets, ohne den Rest der Beschreibung
/// anzufassen. Gemeint sind die Kästchen unter der Überschrift „Fertig, wenn“
/// (oder einer ihrer üblichen Schreibweisen). Hat das Ticket keinen solchen
/// Abschnitt, zählen alle Kästchen der Beschreibung.
enum TicketChecklist {
    /// Überschriften, unter denen die Abnahme-Punkte stehen (klein, ohne Doppelpunkt).
    static let headings: Set<String> = [
        "fertig, wenn", "fertig wenn", "done when", "definition of done", "acceptance criteria", "akzeptanzkriterien",
    ]

    enum Failure: Error, Equatable {
        case noItems
        /// Keine Nummer und kein Text passt.
        case notFound(String)
        /// Der Text passt auf mehrere Kästchen.
        case ambiguous(String, [TicketChecklistItem])
    }

    static func hasSection(_ description: String) -> Bool {
        sectionRange(in: description.components(separatedBy: "\n")) != nil
    }

    static func items(in description: String) -> [TicketChecklistItem] {
        let lines = description.components(separatedBy: "\n")
        let range = sectionRange(in: lines) ?? 0..<lines.count
        var found: [TicketChecklistItem] = []
        for index in range {
            guard let box = box(in: lines[index]) else { continue }
            found.append(TicketChecklistItem(number: found.count + 1, text: box.text, isDone: box.isDone, line: index))
        }
        return found
    }

    /// `nil`, wenn das Ticket keine Kästchen hat.
    static func progress(in description: String) -> TicketChecklistProgress? {
        let all = items(in: description)
        return all.isEmpty ? nil : TicketChecklistProgress(done: all.filter(\.isDone).count, total: all.count)
    }

    /// Setzt die genannten Kästchen. Ein Verweis ist eine Nummer oder ein Stück
    /// des Textes, das auf genau ein Kästchen passt. Liefert die neue
    /// Beschreibung und die Kästchen, die sich geändert haben.
    static func setting(_ references: [String], done: Bool, in description: String) throws
        -> (description: String, changed: [TicketChecklistItem]) {
        let all = items(in: description)
        guard !all.isEmpty else { throw Failure.noItems }
        var lines = description.components(separatedBy: "\n")
        var changed: [TicketChecklistItem] = []
        for reference in references {
            var item = try resolve(reference, in: all)
            guard item.isDone != done, !changed.contains(where: { $0.number == item.number }) else { continue }
            lines[item.line] = mark(lines[item.line], done: done)
            item.isDone = done
            changed.append(item)
        }
        return (lines.joined(separator: "\n"), changed)
    }

    static func resolve(_ reference: String, in items: [TicketChecklistItem]) throws -> TicketChecklistItem {
        let wanted = reference.trimmingCharacters(in: .whitespaces)
        if let number = Int(wanted) {
            guard let item = items.first(where: { $0.number == number }) else { throw Failure.notFound(reference) }
            return item
        }
        let hits = items.filter { $0.text.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        switch hits.count {
        case 1: return hits[0]
        case 0: throw Failure.notFound(reference)
        default: throw Failure.ambiguous(reference, hits)
        }
    }

    // MARK: Zeilen

    /// Zeilen des Abschnitts unter der Überschrift, bis zur nächsten Überschrift
    /// derselben oder einer höheren Ebene.
    private static func sectionRange(in lines: [String]) -> Range<Int>? {
        for (index, line) in lines.enumerated() {
            guard let heading = heading(line), headings.contains(heading.title) else { continue }
            let end = lines[(index + 1)...].firstIndex { other in
                if let next = self.heading(other) { return next.level <= heading.level }
                return false
            } ?? lines.count
            return (index + 1)..<end
        }
        return nil
    }

    private static func heading(_ line: String) -> (level: Int, title: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let level = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(level), trimmed.dropFirst(level).first == " " else { return nil }
        var title = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces).lowercased()
        if title.hasSuffix(":") { title.removeLast() }
        // Linear lässt Fettschrift in Überschriften zu.
        title = title.replacingOccurrences(of: "*", with: "")
        return (level, title)
    }

    /// Erkennt `- [ ] Text`, `* [x] Text` und `+ [X] Text`, auch eingerückt.
    private static func box(in line: String) -> (isDone: Bool, text: String)? {
        guard let match = line.range(of: #"^\s*[-*+]\s+\[([ xX])\]\s+"#, options: .regularExpression) else { return nil }
        let head = line[match]
        guard let open = head.firstIndex(of: "[") else { return nil }
        let mark = head[head.index(after: open)]
        return (mark != " ", String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    private static func mark(_ line: String, done: Bool) -> String {
        guard let match = line.range(of: #"\[([ xX])\]"#, options: .regularExpression) else { return line }
        return line.replacingCharacters(in: match, with: done ? "[x]" : "[ ]")
    }
}
