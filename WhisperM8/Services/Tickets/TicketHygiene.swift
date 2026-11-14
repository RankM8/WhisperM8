import Foundation

// MARK: - Ordnung der Tickets (für `tickets doctor`)

/// Was an offenen Tickets auffällt, ohne dass es ein Fehler wäre: Dinge, die
/// beim Aufräumen jemand ansehen sollte.
struct TicketHygieneFinding: Equatable {
    enum Kind: Equatable {
        /// Offenes Ticket ohne Projekt.
        case noProject
        /// Eingeplant oder in Arbeit, aber ohne Abschnitt „Fertig, wenn“.
        case noCriteria
        /// In Arbeit, und nie hat ein Chat daran gehangen.
        case startedWithoutChat
        /// Eingeplant oder in Arbeit und seit Wochen nicht angefasst.
        case stale
    }

    var kind: Kind
    /// Ticket-Nummern, sortiert.
    var keys: [String]
}

enum TicketHygiene {
    static let staleAfterDays = 21

    static func findings(in tickets: [Ticket], now: Date) -> [TicketHygieneFinding] {
        let open = tickets.filter { !$0.status.kind.isClosed }
        let planned = open.filter { $0.status.kind == .unstarted || $0.status.kind == .started }
        let limit = now.addingTimeInterval(-Double(staleAfterDays) * 86_400)
        let groups: [(TicketHygieneFinding.Kind, [Ticket])] = [
            (.noProject, open.filter { $0.project == nil }),
            // Kästchen ohne die Überschrift genügen: `tickets check` arbeitet auch damit.
            (.noCriteria, planned.filter { !TicketChecklist.hasSection($0.description) && TicketChecklist.items(in: $0.description).isEmpty }),
            // Ein abgegebenes Ticket (beendete Verknüpfung) wartet auf den Merge, nicht auf einen Chat.
            (.startedWithoutChat, open.filter { $0.status.kind == .started && $0.links.isEmpty }),
            (.stale, planned.filter { ($0.updatedAt ?? now) < limit }),
        ]
        return groups.compactMap { kind, hits in
            hits.isEmpty ? nil : TicketHygieneFinding(kind: kind, keys: hits.map(\.key).sorted(by: TicketBoardBuilder.keyOrder))
        }
    }
}

// MARK: - Tabelle Bereich, Ordner, Projekt

/// Eine Zeile der Tabelle in der Doku eines Projekts, die sagt, welcher
/// Bereich der Software zu welchem Projekt im Ticket-Werkzeug gehört und wo
/// seine Doku liegt.
struct TicketArea: Equatable {
    var area: String
    /// Ordner oder Dateien relativ zum Projektordner.
    var paths: [String]
    var project: String
}

enum TicketAreasTable {
    /// Liest die erste Markdown-Tabelle, deren Kopf eine Spalte für den Ordner
    /// und eine für das Projekt hat. `nil`, wenn es keine solche Tabelle gibt.
    static func parse(_ markdown: String) -> [TicketArea]? {
        let lines = markdown.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let head = cells(line).map { $0.lowercased() }
            guard let pathColumn = head.firstIndex(where: { $0.contains("ordner") || $0.contains("folder") }),
                  let projectColumn = head.firstIndex(where: { $0.contains("projekt") || $0.contains("project") }),
                  index + 1 < lines.count, isDivider(lines[index + 1]) else { continue }
            let areaColumn = head.firstIndex { $0.contains("bereich") || $0.contains("area") } ?? 0
            var areas: [TicketArea] = []
            for row in lines[(index + 2)...] {
                let values = cells(row)
                guard !values.isEmpty else { break }
                func value(_ column: Int) -> String { column < values.count ? values[column] : "" }
                let project = plain(value(projectColumn))
                guard !project.isEmpty else { continue }
                let paths = value(pathColumn).split(separator: ",").map { target(String($0)) }
                    .filter { !$0.isEmpty && $0 != "–" && $0 != "-" }
                areas.append(TicketArea(area: plain(value(areaColumn)), paths: paths, project: project))
            }
            return areas
        }
        return nil
    }

    /// Abweichungen zwischen Tabelle, Ticket-Werkzeug und Dateisystem, als
    /// fertige Sätze für den Prüfbericht.
    static func findings(areas: [TicketArea], projects: [String], exists: (String) -> Bool) -> [String] {
        var out: [String] = []
        let listed = Set(areas.map { $0.project.lowercased() })
        let known = Set(projects.map { $0.lowercased() })
        for project in projects where !listed.contains(project.lowercased()) {
            out.append("Projekt „\(project)“ steht nicht in der Tabelle")
        }
        for area in areas {
            if !known.contains(area.project.lowercased()) {
                out.append("„\(area.project)“ steht in der Tabelle, aber nicht im Ticket-Werkzeug")
            }
            if area.paths.isEmpty {
                out.append("Projekt „\(area.project)“ hat keinen Doku-Ordner")
            }
            for path in area.paths where !exists(path) {
                out.append("Doku fehlt: \(path) (\(area.project))")
            }
        }
        return out
    }

    private static func cells(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return [] }
        var parts = trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        parts.removeFirst()
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    private static func isDivider(_ line: String) -> Bool {
        let parts = cells(line)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0 == "-" || $0 == ":" } }
    }

    /// Pfad aus einer Zelle: bei einem Link das Ziel, sonst der Text ohne Backticks.
    private static func target(_ text: String) -> String {
        if let match = text.range(of: #"\]\(([^)]*)\)"#, options: .regularExpression) {
            return String(text[match]).dropFirst(2).dropLast().trimmingCharacters(in: .whitespaces)
        }
        return plain(text)
    }

    /// Ohne Backticks und Link-Schreibweise: `[Text](ziel)` → `Text`.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Bild für den Abschluss

enum TicketImage {
    /// Größer wird nichts hochgeladen.
    static let maxBytes = 5 * 1024 * 1024

    /// Stimmt der Anfang der Datei zum Medientyp? Die Endung allein sagt nichts:
    /// Sonst ginge jede Datei als „Bild“ hoch, und niemand sähe es.
    static func looksLike(_ contentType: String, _ data: Data) -> Bool {
        let head = [UInt8](data.prefix(12))
        switch contentType {
        case "image/png": return head.starts(with: [0x89, 0x50, 0x4E, 0x47])
        case "image/jpeg": return head.starts(with: [0xFF, 0xD8, 0xFF])
        case "image/gif": return head.starts(with: Array("GIF8".utf8))
        case "image/webp": return head.count == 12 && head.starts(with: Array("RIFF".utf8)) && Array(head[8...]) == Array("WEBP".utf8)
        default: return false
        }
    }

    /// Medientyp nach Endung; `nil` für alles, was kein übliches Bild ist.
    static func contentType(forPath path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return nil
        }
    }
}
