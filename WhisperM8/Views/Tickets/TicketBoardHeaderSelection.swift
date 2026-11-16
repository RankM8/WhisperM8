import Foundation

// Kopf und Reiter des Ticket-Boards mit Controller und Tastatur (WM8-91,
// Paket 3d, Auftrag Giuliano 16.11.2026: „Das ganze Board, auch die ganzen
// Filteransichten, müsste bedienbar sein“; seit WM8-125 Reiter statt Filter).
// Pur, neben `TicketBoardSelection`.
//
// Weg: ▲ über die oberste Karte (bzw. Zeile, oberstes Ticket der Triage)
// führt in die unterste Kopfzeile, ▲ weiter in die darüber. ◀ ▶ wandern durch
// die Knöpfe einer Zeile, ▼ unter der untersten Zeile zurück auf die Karte,
// von der man kam. Nur Kreuz schaltet; Bewegen wählt nur aus, auch gehalten.

/// Ein Knopf im Kopf. Reihenfolge der Zeilen wie am Bildschirm.
enum TicketHeaderItem: Hashable {
    // Kopfzeile von Board und Liste
    case back, modeBoard, modeList, copyList, refresh
    // Kopfzeile der Triage
    case closeTriage, copyLink, handOff, openInLinear
    // Reiterzeile (WM8-125): Ansichten aus Linear und „Mehr“
    case view(String)
    case moreViews
}

/// Stelle im Kopf: Zeile (0 = oben) und Knopf in der Zeile.
struct TicketHeaderSpot: Equatable, Sendable {
    var row: Int
    var index: Int
}

/// Was der Kopf zeigt, soweit es die Knöpfe bestimmt.
struct TicketHeaderLayout: Equatable {
    var rows: [[TicketHeaderItem]]

    /// Board und Liste: oben „← Chats“, Liste, Board, „Liste kopieren“,
    /// Aktualisieren; darunter die Reiter, wie sie am Bildschirm stehen, und
    /// „Mehr“, wenn nicht alle in die Zeile passen (WM8-125).
    static func board(hasBack: Bool, tabs: [String], hasMore: Bool) -> TicketHeaderLayout {
        var top: [TicketHeaderItem] = hasBack ? [.back] : []
        top += [.modeList, .modeBoard, .copyList, .refresh]
        let row = tabs.map(TicketHeaderItem.view) + (hasMore ? [.moreViews] : [])
        return TicketHeaderLayout(rows: [top, row])
    }

    /// Triage: eine Zeile mit „← Chats“, „Board“ (zurück), Link, → Jarvis
    /// (nur mit Board-Chat), In Linear öffnen (nur mit Adresse), Aktualisieren.
    static func triage(hasBack: Bool, hasBoardChat: Bool, hasURL: Bool) -> TicketHeaderLayout {
        var row: [TicketHeaderItem] = hasBack ? [.back] : []
        row += [.closeTriage, .copyLink]
        if hasBoardChat { row.append(.handOff) }
        if hasURL { row.append(.openInLinear) }
        row.append(.refresh)
        return TicketHeaderLayout(rows: [row])
    }

    func item(at spot: TicketHeaderSpot) -> TicketHeaderItem? {
        guard rows.indices.contains(spot.row), rows[spot.row].indices.contains(spot.index) else { return nil }
        return rows[spot.row][spot.index]
    }

    /// Einstieg von unten: in die unterste Zeile. Steht dort ein gemerkter
    /// Knopf noch, wieder auf ihm (`last`), sonst auf dem ersten.
    func entry(remembering last: TicketHeaderItem? = nil) -> TicketHeaderSpot? {
        guard let row = rows.indices.last(where: { !rows[$0].isEmpty }) else { return nil }
        if let last, let index = rows[row].firstIndex(of: last) { return TicketHeaderSpot(row: row, index: index) }
        return TicketHeaderSpot(row: row, index: 0)
    }

    /// Eine Stelle, die nach einem neuen Abzug (andere Reiter) nicht mehr
    /// passt, rückt auf den nächsten Knopf derselben Zeile.
    func reconcile(_ spot: TicketHeaderSpot) -> TicketHeaderSpot? {
        guard !rows.isEmpty else { return nil }
        let row = min(max(spot.row, 0), rows.count - 1)
        guard !rows[row].isEmpty else { return entry() }
        return TicketHeaderSpot(row: row, index: min(max(spot.index, 0), rows[row].count - 1))
    }
}

/// Ergebnis eines Schritts im Kopf.
enum TicketHeaderStep: Equatable {
    /// Neue Stelle im Kopf.
    case spot(TicketHeaderSpot)
    /// Am Rand: bleibt, wo es ist (still).
    case stay
    /// ▼ unter der untersten Zeile: zurück auf die Karte.
    case leave
}

enum TicketHeaderSelection {
    /// ◀ ▶ in der Zeile, ohne Umlauf. ▲ ▼ zwischen den Zeilen; der Knopf in
    /// der neuen Zeile ist der mit derselben Nummer, höchstens der letzte.
    static func step(_ spot: TicketHeaderSpot, _ direction: TicketBoardMove,
                     in layout: TicketHeaderLayout) -> TicketHeaderStep {
        guard let spot = layout.reconcile(spot) else { return .leave }
        let row = layout.rows[spot.row]
        switch direction {
        case .left:
            return spot.index > 0 ? .spot(TicketHeaderSpot(row: spot.row, index: spot.index - 1)) : .stay
        case .right:
            return spot.index + 1 < row.count ? .spot(TicketHeaderSpot(row: spot.row, index: spot.index + 1)) : .stay
        case .up:
            guard let above = (0..<spot.row).last(where: { !layout.rows[$0].isEmpty }) else { return .stay }
            return .spot(TicketHeaderSpot(row: above, index: min(spot.index, layout.rows[above].count - 1)))
        case .down:
            guard let below = ((spot.row + 1)..<layout.rows.count).first(where: { !layout.rows[$0].isEmpty }) else {
                return .leave
            }
            return .spot(TicketHeaderSpot(row: below, index: min(spot.index, layout.rows[below].count - 1)))
        }
    }

    // MARK: Liste unter „Mehr“ (WM8-125)

    /// ▲ ▼ in der Liste, ohne Umlauf.
    static func pickerStep(_ index: Int, _ direction: TicketBoardMove, count: Int) -> Int {
        guard count > 0 else { return 0 }
        switch direction {
        case .up: return max(0, index - 1)
        case .down: return min(count - 1, index + 1)
        case .left, .right: return min(max(index, 0), count - 1)
        }
    }
}
