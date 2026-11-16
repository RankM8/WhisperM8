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
    /// Erstes Ticket unter „N weitere“; dort öffnet die Triage (WM8-91).
    var firstHiddenKey: String? = nil

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
            let firstHidden = shown.hidden > 0 ? lane.entries[shown.entries.count].ticket.key : nil
            return TicketBoardColumnKeys(id: lane.id, keys: shown.entries.map(\.ticket.key), hidden: shown.hidden,
                                         isFolded: lane.isFolded, firstHiddenKey: firstHidden)
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
/// einem Terminal oder Textfeld liegt; das prüft der Aufrufer (Ausnahme:
/// `isBoardChatKey` im Terminal des Board-Chats).
///
/// Paket 3c (WM8-91): dieselben Wege wie am Controller, Plan „Tastatur“:
/// Pfeile wie Stick und Steuerkreuz, Return wie Kreuz, Esc wie Kreis,
/// ⌘⌥←/→ und ⌘⇧←/→ wie L1/R1, ⌘O wie L3, ⌘R wie R3, ⌘J wie Dreieck.
enum TicketBoardKey: Equatable {
    /// J: nächstes Ticket (wie R1).
    case next
    /// K: voriges Ticket (wie L1).
    case previous
    /// Esc: zurück (Chat-Zeile → Liste → Board), wie Kreis.
    case close
    /// ⌘C: Link des gewählten Tickets (Entscheidung Giuliano, 15.11.2026;
    /// ⌘⇧C bleibt der Zwischenablage-Verlauf). Markierter Text geht vor; das
    /// prüft der Aufrufer.
    case copyLink
    /// ↑ ↓ ← →: Auswahl, Liste der Triage, Chat-Zeile; → am Rand in den
    /// Board-Chat. `isRepeat`: gehalten, dann nie über den Rand.
    case move(ControllerDirection, isRepeat: Bool)
    /// Return: Ticket groß bzw. auf der Chat-Zeile „Zum Chat“.
    case open
    /// ⌘⌥←/→ und ⌘⇧←/→: voriges/nächstes Ticket.
    case adjacent(Int)
    /// ⌘O: In Linear öffnen.
    case openInLinear
    /// ⌘R: Aktualisieren (im Ticket-Modus statt „Sitzungen neu lesen“).
    case refresh
    /// ⌘J: → Jarvis (Ticket ins Feld des Board-Chats).
    case handOff
    /// ⌘K: Menü-Karte am Ticket, bedient mit ↑ ↓, Return und Esc wie die
    /// Insel per Tastatur.
    case menu
    /// ⌘←: aus dem Terminal des Board-Chats zurück aufs Ticket
    /// (Entscheidung 16.11.2026).
    case leaveBoardChat

    /// Ohne Modifier für Pfeile, Return, Esc, J, K. Pfeiltasten tragen
    /// `.function`/`.numericPad`, deshalb nur die vier echten Modifier
    /// vergleichen (Muster `TabNavShortcut`). Buchstaben über das Zeichen,
    /// nicht die Taste: Auf anderen Belegungen liegen sie woanders.
    static func resolve(keyCode: UInt16, characters: String?, modifiers: ModifierSet,
                        isRepeat: Bool = false) -> TicketBoardKey? {
        let character = characters?.lowercased()
        if modifiers == .command {
            switch character {
            case "c": return .copyLink
            case "o": return .openInLinear
            case "r": return .refresh
            case "j": return .handOff
            case "k": return .menu
            default: break
            }
            return keyCode == 123 ? .leaveBoardChat : nil
        }
        if modifiers == [.command, .option] || modifiers == [.command, .shift] {
            switch keyCode {
            case 123: return .adjacent(-1)
            case 124: return .adjacent(1)
            default: return nil
            }
        }
        guard modifiers.isEmpty else { return nil }
        switch keyCode {
        case 125: return .move(.down, isRepeat: isRepeat)
        case 126: return .move(.up, isRepeat: isRepeat)
        case 123: return .move(.left, isRepeat: isRepeat)
        case 124: return .move(.right, isRepeat: isRepeat)
        case 36, 76: return .open     // Return, Enter
        case 53: return .close        // Esc
        default: break
        }
        switch character {
        case "j": return .next
        case "k": return .previous
        default: return nil
        }
    }

    /// Im Terminal des Board-Chats gehören alle Tasten dem Chat, bis auf diese:
    /// zurück aufs Ticket, Ticket blättern (E2: auch im Board-Chat) und → Jarvis.
    var isBoardChatKey: Bool {
        switch self {
        case .leaveBoardChat, .adjacent, .handOff: return true
        default: return false
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

// MARK: - Controller: Stellen, Rand, Liste, Chat-Zeile (WM8-91, pur)

/// Wo die Auswahl auf dem Board stehen kann: auf einer Karte oder auf
/// „N weitere“ unter den gezeigten Karten einer Spalte.
enum TicketBoardSpot: Equatable {
    case card(String)
    case more(column: String)
}

/// Rand, an dem eine Bewegung stehen blieb. Der Controller führt von dort
/// weiter: links aus der ersten Spalte (oder der Liste) in die Seitenleiste,
/// rechts in den Board-Chat (WM8-91 Paket 3a).
enum TicketBoardEdge: Equatable {
    case top, bottom, left, right
}

/// Ergebnis eines Schritts: neue Stelle und, falls es nicht weiterging, der Rand.
struct TicketBoardStep: Equatable {
    var spot: TicketBoardSpot?
    var edge: TicketBoardEdge? = nil
}

extension TicketBoardSelection {
    /// Ein Schritt mit Steuerkreuz oder Stick, „N weitere“ eingeschlossen. Am
    /// Rand bleibt die Stelle, und `edge` nennt ihn. Ohne Stelle (oder wenn sie
    /// nicht mehr gezeigt wird) beginnt jeder Schritt bei der Start-Auswahl.
    static func step(_ spot: TicketBoardSpot?, _ direction: TicketBoardMove, in columns: [TicketBoardColumnKeys]) -> TicketBoardStep {
        guard let (column, row) = place(of: spot, in: columns) else {
            return TicketBoardStep(spot: start(preferred: nil, in: columns).map(TicketBoardSpot.card))
        }
        let current = columns[column]
        let here = spot
        switch direction {
        case .up:
            guard row > 0 else { return TicketBoardStep(spot: here, edge: .top) }
            return TicketBoardStep(spot: .card(current.keys[row - 1]))
        case .down:
            if row + 1 < current.keys.count { return TicketBoardStep(spot: .card(current.keys[row + 1])) }
            if row + 1 == current.keys.count, current.hidden > 0 { return TicketBoardStep(spot: .more(column: current.id)) }
            return TicketBoardStep(spot: here, edge: .bottom)
        case .left, .right:
            let delta = direction == .left ? -1 : 1
            var target = column + delta
            while columns.indices.contains(target), !columns[target].isUsable { target += delta }
            guard columns.indices.contains(target) else {
                return TicketBoardStep(spot: here, edge: direction == .left ? .left : .right)
            }
            let next = columns[target]
            // Höhe ungefähr halten; „N weitere“ zählt als Zeile unter den Karten.
            if row < next.keys.count { return TicketBoardStep(spot: .card(next.keys[row])) }
            if next.hidden > 0 { return TicketBoardStep(spot: .more(column: next.id)) }
            return TicketBoardStep(spot: .card(next.keys[next.keys.count - 1]))
        }
    }

    /// Spalte und Zeile einer Stelle; „N weitere“ steht in der Zeile unter der
    /// letzten Karte.
    static func place(of spot: TicketBoardSpot?, in columns: [TicketBoardColumnKeys]) -> (column: Int, row: Int)? {
        switch spot {
        case .card(let key)?:
            return position(of: key, in: columns)
        case .more(let id)?:
            guard let index = columns.firstIndex(where: { $0.id == id && $0.hidden > 0 && $0.isUsable }) else { return nil }
            return (index, columns[index].keys.count)
        case nil:
            return nil
        }
    }

    /// Ticket, das Kreuz auf dieser Stelle groß öffnet: die Karte selbst, auf
    /// „N weitere“ das erste verborgene Ticket der Spalte, wie der Knopf in
    /// der Ansicht. Die Liste der Triage ist in beiden Fällen die ganze Spalte.
    static func openKey(_ spot: TicketBoardSpot?, in columns: [TicketBoardColumnKeys]) -> String? {
        switch spot {
        case .card(let key)?:
            return position(of: key, in: columns) != nil ? key : nil
        case .more(let id)?:
            return columns.first { $0.id == id }?.firstHiddenKey
        case nil:
            return nil
        }
    }

    /// Start-Auswahl für den Controller (Plan, „Welches Board“): das Ticket
    /// des Chats, aus dem man kommt; sonst die erste Karte der ersten Spalte,
    /// in der etwas wartet (`waiting`); sonst die erste Karte. Was nicht
    /// gezeigt wird, zählt nicht.
    static func controllerStart(preferred: String?, waiting: String?, in columns: [TicketBoardColumnKeys]) -> String? {
        for key in [preferred, waiting].compactMap({ $0 }) where position(of: key, in: columns) != nil { return key }
        return start(preferred: nil, in: columns)
    }

    /// Lesereihenfolge für L1/R1: die gezeigten Karten die Spalte hinunter,
    /// dann oben in der nächsten. Eingeklappte Spalten fehlen.
    static func readingOrder(_ columns: [TicketBoardColumnKeys]) -> [String] {
        columns.filter(\.isUsable).flatMap(\.keys)
    }

    /// Voriges oder nächstes Ticket in Lesereihenfolge. Am Anfang oder Ende
    /// bleibt die Stelle, `edge` ist `.top` bzw. `.bottom`. Von „N weitere“ aus
    /// gilt die letzte Karte der Spalte als Ausgang.
    static func adjacent(_ spot: TicketBoardSpot?, _ step: Int, in columns: [TicketBoardColumnKeys]) -> TicketBoardStep {
        let order = readingOrder(columns)
        guard !order.isEmpty else { return TicketBoardStep(spot: nil) }
        let anchor: String?
        switch spot {
        case .card(let key)?: anchor = key
        case .more(let id)?: anchor = columns.first { $0.id == id }?.keys.last
        case nil: anchor = nil
        }
        guard let anchor, let index = order.firstIndex(of: anchor) else {
            return TicketBoardStep(spot: start(preferred: nil, in: columns).map(TicketBoardSpot.card))
        }
        if case .more = spot, step > 0, index + 1 < order.count { return TicketBoardStep(spot: .card(order[index + 1])) }
        if case .more = spot, step < 0 { return TicketBoardStep(spot: .card(anchor)) }
        let target = index + step
        guard order.indices.contains(target) else { return TicketBoardStep(spot: spot, edge: step < 0 ? .top : .bottom) }
        return TicketBoardStep(spot: .card(order[target]))
    }

    /// Ein Schritt im Modus Liste: ▲ ▼ durch die Tickets in Reihenfolge der
    /// Liste; ◀ ▶ sind Rand (links führt der Controller in die Seitenleiste).
    static func stepInList(_ key: String?, _ direction: TicketBoardMove, keys: [String]) -> (key: String?, edge: TicketBoardEdge?) {
        guard let first = keys.first else { return (nil, nil) }
        guard let key, let index = keys.firstIndex(of: key) else { return (first, nil) }
        switch direction {
        case .up: return index > 0 ? (keys[index - 1], nil) : (key, .top)
        case .down: return index + 1 < keys.count ? (keys[index + 1], nil) : (key, .bottom)
        case .left: return (key, .left)
        case .right: return (key, .right)
        }
    }
}

/// Fokus in der Triage: die Liste links oder eine Zeile unter „Chats am
/// Ticket“ (Index in den Chats des gezeigten Tickets).
enum TicketTriageFocus: Equatable {
    case list
    case chat(Int)
}

/// Was ein Schritt in der Triage bewirkt.
enum TicketTriageStep: Equatable {
    /// Voriges (−1) oder nächstes (+1) Ticket der Liste.
    case ticket(Int)
    case focus(TicketTriageFocus)
    /// Nichts mehr in dieser Richtung.
    case edge(TicketBoardEdge)
}

extension TicketBoardSelection {
    /// In der Liste: ▲ ▼ wechseln das Ticket, ▶ geht in „Chats am Ticket“
    /// (nur, wenn es Chats hat), ◀ ist Rand (Seitenleiste). Auf einer
    /// Chat-Zeile: ▲ ▼ zwischen den Chats, ◀ zurück in die Liste, ▶ ist Rand
    /// (dort kommt mit WM8-113 der Board-Chat).
    static func triageStep(_ focus: TicketTriageFocus, _ direction: TicketBoardMove, chatCount: Int) -> TicketTriageStep {
        switch focus {
        case .list:
            switch direction {
            case .up: return .ticket(-1)
            case .down: return .ticket(1)
            case .left: return .edge(.left)
            case .right: return chatCount > 0 ? .focus(.chat(0)) : .edge(.right)
            }
        case .chat(let index):
            switch direction {
            case .up: return index > 0 ? .focus(.chat(index - 1)) : .edge(.top)
            case .down: return index + 1 < chatCount ? .focus(.chat(index + 1)) : .edge(.bottom)
            case .left: return .focus(.list)
            case .right: return .edge(.right)
            }
        }
    }

    /// Der Fokus nach einem Wechsel des Tickets oder einem neuen Abzug: eine
    /// Chat-Zeile, die es nicht mehr gibt, rückt auf die letzte; ohne Chats
    /// zurück in die Liste.
    static func reconcile(_ focus: TicketTriageFocus, chatCount: Int) -> TicketTriageFocus {
        guard case .chat(let index) = focus else { return focus }
        guard chatCount > 0 else { return .list }
        return .chat(min(index, chatCount - 1))
    }
}
