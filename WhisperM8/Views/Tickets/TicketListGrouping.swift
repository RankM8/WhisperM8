import Foundation

// MARK: - Liste nach der Ansicht aus Linear (WM8-125, pur)

/// Eine Zeile der Liste: das Ticket, wie tief es eingerückt ist, und bei einer
/// Unteraufgabe ohne Eltern-Ticket in der Ansicht die Nummer des Eltern-Tickets
/// („↳ WM8-91“).
struct TicketListRow: Equatable, Identifiable {
    var entry: TicketBoardEntry
    var depth: Int
    var parentKeyOutsideView: String?
    /// Unteraufgaben in der Ansicht und wie viele davon erledigt sind; nur am Eltern-Ticket.
    var children: TicketChildProgress?

    var id: String { entry.ticket.key }
}

struct TicketChildProgress: Equatable {
    var done: Int
    var total: Int
}

/// Was vor dem Namen einer Gruppe steht.
enum TicketListGroupSymbol: Equatable {
    case status(TicketStatus)
    case project
    case priority(Int)
    case person
    case label
    case none
}

/// Eine Gruppe der Liste mit Kopf (Name, Zahl) und ihren Zeilen.
struct TicketListGroup: Equatable, Identifiable {
    /// Bleibt gleich, solange die Gruppe dieselbe ist (Auf- und Zuklappen hängt daran).
    var id: String
    var title: String
    var symbol: TicketListGroupSymbol
    var rows: [TicketListRow]
    /// Status, der auf den Nutzer wartet (nur bei Gruppen nach Status).
    var waitsForMe = false

    var entries: [TicketBoardEntry] { rows.map(\.entry) }
    var agentCount: Int { rows.filter { $0.entry.hasAgent }.count }
}

enum TicketListGrouping {
    /// Tiefer rückt die Liste nicht ein; tiefere Unteraufgaben stehen auf der letzten Stufe.
    static let maxDepth = 2

    /// Gruppen in der Reihenfolge der Ansicht. Unteraufgaben stehen unter ihrem
    /// Eltern-Ticket, wenn es in der Ansicht ist, und gehören zu dessen Gruppe
    /// (wie in Linear); sonst als eigene Zeile mit „↳“. Ohne Unteraufgaben in
    /// der Ansicht (`showsSubIssues` aus) fallen sie weg.
    static func make(entries: [TicketBoardEntry], view: TicketView?, rule: TicketTeamRule) -> [TicketListGroup] {
        let grouping = view?.grouping ?? .status
        let showsSubIssues = view?.showsSubIssues ?? true
        let ordering = view?.ordering ?? .priority
        let visible = showsSubIssues ? entries : entries.filter { $0.ticket.parentKey == nil }
        let keys = Set(visible.map(\.ticket.key))
        let parentOf = Dictionary(visible.compactMap { entry in
            entry.ticket.parentKey.flatMap { keys.contains($0) && $0 != entry.ticket.key ? (entry.ticket.key, $0) : nil }
        }, uniquingKeysWith: { first, _ in first })
        // Eingerückt wird nur, wer über seine Eltern bei einem Ticket ohne Eltern
        // in der Ansicht ankommt. Ein Ring (A unter B, B unter A) bleibt flach,
        // statt zu verschwinden.
        func isRooted(_ key: String) -> Bool {
            var seen: Set<String> = [key]
            var current = key
            while let parent = parentOf[current] {
                guard seen.insert(parent).inserted else { return false }
                current = parent
            }
            return true
        }
        var children: [String: [TicketBoardEntry]] = [:]
        var tops: [TicketBoardEntry] = []
        for entry in visible {
            if let parent = parentOf[entry.ticket.key], isRooted(entry.ticket.key) {
                children[parent, default: []].append(entry)
            } else {
                tops.append(entry)
            }
        }
        let sort: (TicketBoardEntry, TicketBoardEntry) -> Bool = { order($0, $1, by: ordering) }

        var placed = Set<String>()
        func rows(for entry: TicketBoardEntry, depth: Int) -> [TicketListRow] {
            guard placed.insert(entry.ticket.key).inserted else { return [] }
            let kids = (children[entry.ticket.key] ?? []).sorted(by: sort)
            let parentOutside = depth == 0 ? entry.ticket.parentKey.flatMap { keys.contains($0) ? nil : $0 } : nil
            var result = [TicketListRow(
                entry: entry, depth: depth, parentKeyOutsideView: parentOutside,
                children: kids.isEmpty ? nil : TicketChildProgress(done: kids.filter { $0.ticket.status.kind.isClosed }.count, total: kids.count))]
            for kid in kids { result += rows(for: kid, depth: min(depth + 1, maxDepth)) }
            return result
        }

        var buckets: [String: (title: String, symbol: TicketListGroupSymbol, sortKey: SortKey, waits: Bool, tops: [TicketBoardEntry])] = [:]
        for entry in tops {
            let slot = bucket(for: entry.ticket, grouping: grouping, rule: rule)
            buckets[slot.id, default: (slot.title, slot.symbol, slot.sortKey, slot.waits, [])].tops.append(entry)
        }
        let ordered = buckets.sorted { lhs, rhs in
            lhs.value.sortKey.isBefore(rhs.value.sortKey, rule: rule) || (lhs.value.sortKey == rhs.value.sortKey && lhs.key < rhs.key)
        }
        return ordered.map { id, bucket in
            TicketListGroup(id: id, title: bucket.title, symbol: bucket.symbol,
                            rows: bucket.tops.sorted(by: sort).flatMap { rows(for: $0, depth: 0) },
                            waitsForMe: bucket.waits)
        }
    }

    /// Innerhalb einer Gruppe: nach Priorität (wie das Board) oder zuletzt geändert zuerst.
    static func order(_ lhs: TicketBoardEntry, _ rhs: TicketBoardEntry, by ordering: TicketViewOrdering) -> Bool {
        switch ordering {
        case .priority:
            return TicketBoardLayout.order(lhs, rhs)
        case .updated:
            let l = lhs.ticket.updatedAt ?? .distantPast, r = rhs.ticket.updatedAt ?? .distantPast
            if l != r { return l > r }
            return TicketBoardLayout.order(lhs, rhs)
        }
    }

    // MARK: Gruppe je Ticket

    enum SortKey: Equatable {
        case status(TicketStatus)
        /// Name; `last` stellt „ohne …“ ans Ende.
        case name(String, last: Bool)
        case priority(Int)

        func isBefore(_ other: SortKey, rule: TicketTeamRule) -> Bool {
            switch (self, other) {
            case let (.status(l), .status(r)):
                return TicketBoardLanes.laneOrder(l, r, rule: rule)
            case let (.name(l, lLast), .name(r, rLast)):
                if lLast != rLast { return rLast }
                return l.localizedStandardCompare(r) == .orderedAscending
            case let (.priority(l), .priority(r)):
                return (l == 0 ? 9 : l) < (r == 0 ? 9 : r)
            default:
                return false
            }
        }
    }

    static func bucket(for ticket: Ticket, grouping: TicketViewGrouping, rule: TicketTeamRule)
        -> (id: String, title: String, symbol: TicketListGroupSymbol, sortKey: SortKey, waits: Bool) {
        switch grouping {
        case .status, .unsupported:
            // Gleich benannte Status aus verschiedenen Teams stehen in einer Gruppe.
            let status = ticket.status
            return ("status:" + status.name.lowercased(), status.name, .status(status), .status(status),
                    rule.meaning(of: status) == .waitsForMe)
        case .project:
            let name = ticket.project ?? ""
            return ("project:" + name, TicketBoardText.project(name), .project, .name(name, last: name.isEmpty), false)
        case .priority:
            return ("priority:\(ticket.priority)", TicketBoardText.priority(ticket.priority), .priority(ticket.priority),
                    .priority(ticket.priority), false)
        case .assignee:
            let name = ticket.assignee?.name ?? ""
            return ("person:" + (ticket.assignee?.id ?? ""), name.isEmpty ? String(localized: "Nobody") : name, .person,
                    .name(name, last: name.isEmpty), false)
        case .label:
            let name = ticket.labels.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.first ?? ""
            return ("label:" + name, name.isEmpty ? String(localized: "No label") : name, .label,
                    .name(name, last: name.isEmpty), false)
        case .none:
            return ("all", String(localized: "All tickets"), .none, .name("", last: false), false)
        }
    }
}
