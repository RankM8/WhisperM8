import Foundation

// MARK: - Spalten nach echtem Status

/// Eine Spalte des Boards: genau ein Status des Teams.
struct TicketBoardLane: Equatable, Identifiable {
    var status: TicketStatus
    /// Bedeutung des Status nach der Regel des Teams.
    var meaning: TicketStatusMeaning?
    /// Sichtbare Tickets (nach Filter), in der Reihenfolge der Karten.
    var entries: [TicketBoardEntry]

    var id: String { status.id }
    /// Wie viele der sichtbaren Tickets auf den Nutzer warten.
    var waitingCount: Int { entries.filter(\.waitsForMe).count }
}

enum TicketBoardLanes {
    /// So viele Karten zeigt eine Spalte, bevor „N weitere“ kommt. Lange
    /// Spalten (ein Backlog mit 40 Tickets) würden sonst das Board füllen,
    /// und der Rest steht ohnehin in der Liste.
    static let cardLimit = 8

    /// Karten, die eine Spalte zeigt, und wie viele darunter als „N weitere“
    /// stehen. Ansicht, Auswahl und Controller (WM8-91) nehmen genau diese
    /// Liste; keiner schneidet selbst ab.
    static func shown(_ lane: TicketBoardLane, expanded: Bool) -> (entries: [TicketBoardEntry], hidden: Int) {
        let entries = expanded ? lane.entries : Array(lane.entries.prefix(cardLimit))
        return (entries, lane.entries.count - entries.count)
    }

    /// Eine Spalte je offenem Status, der Tickets hat. Welche Status
    /// Spalten bekommen, hängt am ungefilterten Stand: Ein Filter leert eine
    /// Spalte, statt sie verschwinden zu lassen, damit das Board nicht springt.
    ///
    /// Reihenfolge: zuerst Status, die auf den Nutzer warten, dann der
    /// Eingang (Triage), was begonnen ist, was als Nächstes kommt, das Backlog.
    /// Unter den begonnenen stehen die „fertigen“ (gebaut, warten auf andere)
    /// hinter denen in Arbeit. Sonst der weiteste Stand links, also nach der
    /// Stelle im Team absteigend. Die Karten einer Spalte stehen nach Priorität.
    static func make(statuses: [TicketStatus], open: [TicketBoardEntry], visible: [TicketBoardEntry],
                     rule: TicketTeamRule) -> [TicketBoardLane] {
        let used = Set(open.map(\.ticket.status.id))
        var known = statuses.filter { !$0.kind.isClosed && used.contains($0.id) }
        // Ein Status, den die Liste des Teams (noch) nicht kennt, bekommt trotzdem eine Spalte.
        for entry in open where !known.contains(where: { $0.id == entry.ticket.status.id }) {
            known.append(entry.ticket.status)
        }
        var byStatus: [String: [TicketBoardEntry]] = [:]
        for entry in visible { byStatus[entry.ticket.status.id, default: []].append(entry) }
        return known.sorted { laneOrder($0, $1, rule: rule) }.map { status in
            TicketBoardLane(status: status, meaning: rule.meaning(of: status),
                            entries: (byStatus[status.id] ?? []).sorted(by: TicketBoardLayout.order))
        }
    }

    static func laneOrder(_ lhs: TicketStatus, _ rhs: TicketStatus, rule: TicketTeamRule) -> Bool {
        let lm = rule.meaning(of: lhs), rm = rule.meaning(of: rhs)
        if (lm == .waitsForMe) != (rm == .waitsForMe) { return lm == .waitsForMe }
        let lg = group(lhs.kind), rg = group(rhs.kind)
        if lg != rg { return lg < rg }
        if (lm == .done) != (rm == .done) { return rm == .done }
        if lhs.position != rhs.position { return lhs.position > rhs.position }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func group(_ kind: TicketStatusKind) -> Int {
        switch kind {
        case .triage: return 0
        case .started: return 1
        case .unstarted: return 2
        case .backlog: return 3
        case .completed: return 4
        case .canceled: return 5
        }
    }
}
