import Foundation

// MARK: - Auswahl im Board und in der Triage (pur)

/// Woher die Liste links in der Triage kommt. Nach einem neuen Abzug wird sie
/// aus derselben Quelle neu gelesen.
enum TicketTriageSource: Equatable {
    /// Eine Spalte des Boards (ID des Status).
    case lane(statusID: String)
    /// Die Liste (alle sichtbaren Tickets in ihrer Reihenfolge).
    case list
}

/// Die offene Triage: Liste links, gewähltes Ticket groß.
struct TicketTriage: Equatable {
    var source: TicketTriageSource
    /// Überschrift der Liste (Name des Status oder „Liste“).
    var title: String
    /// Ticket-Nummern der Liste in ihrer Reihenfolge.
    var keys: [String]
    /// Gewähltes Ticket; steht immer in `keys`.
    var current: String

    var index: Int { keys.firstIndex(of: current) ?? 0 }
    var hasNext: Bool { index + 1 < keys.count }
    var hasPrevious: Bool { index > 0 }
}

/// Reine Regeln für die Auswahl: welches Ticket gewählt ist, nächstes,
/// voriges, öffnen, schließen, zurück zum Board und was nach einem neuen
/// Abzug gewählt bleibt. Maus, Tastatur und später der Controller (WM8-91)
/// rufen dieselben Funktionen; die Ansicht rechnet nichts davon selbst.
/// Nur Foundation, wie die Tab-Logik (`TabSelectionResolver`).
enum TicketBoardSelection {
    /// Öffnet die Triage für `key` mit der Liste `keys` (die Spalte oder
    /// Liste, aus der das Ticket kommt). `nil`, wenn das Ticket nicht in der
    /// Liste steht.
    static func open(_ key: String, keys: [String], source: TicketTriageSource, title: String) -> TicketTriage? {
        guard keys.contains(key) else { return nil }
        return TicketTriage(source: source, title: title, keys: keys, current: key)
    }

    /// Nächstes Ticket. Am Ende bleibt es stehen: Ein Sprung an den Anfang
    /// ließe glauben, die Liste ginge weiter.
    static func next(_ triage: TicketTriage) -> TicketTriage {
        move(triage, by: 1)
    }

    static func previous(_ triage: TicketTriage) -> TicketTriage {
        move(triage, by: -1)
    }

    /// Ein Klick in der Liste links.
    static func select(_ key: String, in triage: TicketTriage) -> TicketTriage {
        guard triage.keys.contains(key) else { return triage }
        var moved = triage
        moved.current = key
        return moved
    }

    /// Zurück zum Board: Die Karte des zuletzt gezeigten Tickets bleibt gewählt.
    static func close(_ triage: TicketTriage) -> String {
        triage.current
    }

    /// Neuer Abzug: Die Liste wird aus ihrer Quelle neu gelesen (`fresh`).
    /// Das gezeigte Ticket bleibt, solange es in der Liste steht. Fällt es
    /// heraus (erledigt, anderer Status), rückt der Nachbar an derselben
    /// Stelle nach, am Ende der vorige. Ist die Liste leer, schließt die
    /// Triage (`nil`).
    static func reconcile(_ triage: TicketTriage, fresh: [String]) -> TicketTriage? {
        guard !fresh.isEmpty else { return nil }
        var updated = triage
        updated.keys = fresh
        if fresh.contains(triage.current) { return updated }
        // Der nächste noch vorhandene Nachfolger aus der alten Liste, sonst der Vorgänger.
        let old = triage.keys
        let at = old.firstIndex(of: triage.current) ?? 0
        let after = old.suffix(from: min(at + 1, old.count)).first(where: fresh.contains)
        let before = old.prefix(at).last(where: fresh.contains)
        updated.current = after ?? before ?? fresh[min(at, fresh.count - 1)]
        return updated
    }

    private static func move(_ triage: TicketTriage, by step: Int) -> TicketTriage {
        let target = triage.index + step
        guard triage.keys.indices.contains(target) else { return triage }
        var moved = triage
        moved.current = triage.keys[target]
        return moved
    }
}

// MARK: - Auswahl auf dem Board (pur)

/// Eine Spalte, wie die Auswahl sie sieht: die gezeigten Karten
/// (`TicketBoardLanes.shown`), dazu ob sie eingeklappt ist.
struct TicketBoardColumnKeys: Equatable {
    var id: String
    /// Ticket-Nummern der gezeigten Karten, von oben nach unten.
    var keys: [String]
    /// So viele stehen darunter als „N weitere · in der Liste“.
    var hidden: Int
    var isFolded: Bool

    /// Eine Spalte, in der die Auswahl stehen kann.
    var isUsable: Bool { !isFolded && !keys.isEmpty }
}

enum TicketBoardMove: Equatable {
    case up, down, left, right
}

extension TicketBoardSelection {
    /// Spalten des Boards für die Auswahl, aus derselben Regel wie die Ansicht.
    static func columns(_ lanes: [TicketBoardLane]) -> [TicketBoardColumnKeys] {
        lanes.map { lane in
            let shown = TicketBoardLanes.shown(lane, expanded: false)
            return TicketBoardColumnKeys(id: lane.id, keys: shown.entries.map(\.ticket.key), hidden: shown.hidden,
                                         isFolded: lane.isFolded)
        }
    }

    /// Wo die Auswahl steht: Spalte und Zeile der Karte; `nil`, wenn die
    /// Karte nicht (mehr) gezeigt wird.
    static func position(of key: String?, in columns: [TicketBoardColumnKeys]) -> (column: Int, row: Int)? {
        guard let key else { return nil }
        for (index, column) in columns.enumerated() {
            if let row = column.keys.firstIndex(of: key) { return (index, row) }
        }
        return nil
    }

    /// Start-Auswahl: das gewünschte Ticket, wenn es gezeigt wird, sonst die
    /// oberste Karte der ersten benutzbaren Spalte.
    static func start(preferred: String?, in columns: [TicketBoardColumnKeys]) -> String? {
        if position(of: preferred, in: columns) != nil { return preferred }
        return columns.first(where: \.isUsable)?.keys.first
    }

    /// Ein Schritt auf dem Board. ▲ ▼ innerhalb der Spalte (bleibt am Rand
    /// stehen), ◀ ▶ in die nächste benutzbare Spalte; eingeklappte und leere
    /// Spalten werden übersprungen, die Zeile bleibt so nah wie möglich. Ohne
    /// Auswahl beginnt jeder Schritt bei der Start-Auswahl. `nil` nur, wenn
    /// das Board keine Karte zeigt.
    static func move(_ key: String?, _ direction: TicketBoardMove, in columns: [TicketBoardColumnKeys]) -> String? {
        guard let (column, row) = position(of: key, in: columns) else { return start(preferred: nil, in: columns) }
        let keys = columns[column].keys
        switch direction {
        case .up: return keys[max(row - 1, 0)]
        case .down: return keys[min(row + 1, keys.count - 1)]
        case .left, .right:
            let step = direction == .left ? -1 : 1
            var target = column + step
            while columns.indices.contains(target), !columns[target].isUsable { target += step }
            guard columns.indices.contains(target) else { return keys[row] }
            let next = columns[target].keys
            return next[min(row, next.count - 1)]
        }
    }
}

// MARK: - Tasten in der Triage (pur)

/// Was eine Taste in der Ticket-Ansicht tut. Nur, wenn der Fokus nicht in
/// einem Terminal oder Textfeld liegt; das prüft der Aufrufer.
enum TicketBoardKey: Equatable {
    case next
    case previous
    case close

    /// J/↓ nächstes, K/↑ voriges, Esc zurück zum Board. Ohne Modifier;
    /// Pfeiltasten tragen `.function`/`.numericPad`, deshalb nur die vier
    /// echten Modifier vergleichen (Muster `TabNavShortcut`).
    static func resolve(keyCode: UInt16, characters: String?, modifiers: ModifierSet) -> TicketBoardKey? {
        guard modifiers.isEmpty else { return nil }
        switch keyCode {
        case 125: return .next       // ↓
        case 126: return .previous   // ↑
        case 53: return .close       // Esc
        default: break
        }
        switch characters?.lowercased() {
        case "j": return .next
        case "k": return .previous
        default: return nil
        }
    }

    /// Die vier Modifier, die zählen; unabhängig von AppKit für Tests.
    struct ModifierSet: OptionSet, Equatable {
        let rawValue: Int
        static let command = ModifierSet(rawValue: 1)
        static let option = ModifierSet(rawValue: 2)
        static let control = ModifierSet(rawValue: 4)
        static let shift = ModifierSet(rawValue: 8)
    }
}
