import AppKit
import Foundation

/// Eine Zeile unter „Chats am Ticket“, wie der Controller sie braucht.
struct TicketControllerChatLine: Equatable {
    /// Chat auf diesem Rechner; `nil`: anderer Rechner oder gelöscht (dann
    /// geht „Zum Chat“ nicht).
    var chatID: UUID?
    var name: String
}

// MARK: - Controller (WM8-91, Paket 2)

/// Wendet die puren Regeln aus `TicketBoardSelection` auf den Zustand der
/// Ansicht an, für den Controller (und später die Tastatur über die Insel,
/// Paket 3). Liest nur; nichts hier schreibt in das Ticket-Werkzeug.
extension TicketBoardViewModel {
    /// Wo die Auswahl auf dem Board steht: Karte oder „N weitere“.
    var boardSpot: TicketBoardSpot? {
        if let moreColumn { return .more(column: moreColumn) }
        return selectedKey.map(TicketBoardSpot.card)
    }

    func setBoardSpot(_ spot: TicketBoardSpot?) {
        switch spot {
        case .card(let key)?:
            if selectedKey != key { selectedKey = key }
            if moreColumn != nil { moreColumn = nil }
        case .more(let column)?:
            if selectedKey != nil { selectedKey = nil }
            if moreColumn != column { moreColumn = column }
        case nil:
            selectedKey = nil
            moreColumn = nil
        }
    }

    var boardColumns: [TicketBoardColumnKeys] { TicketBoardSelection.columns(presentation.lanes) }

    /// Chats am gezeigten Ticket in der Reihenfolge der Eigenschaften rechts.
    var chatLines: [TicketControllerChatLine] {
        (detail?.agents ?? []).map { line in
            let chat = line.entry.agents.first?.chat
            return TicketControllerChatLine(chatID: chat?.id, name: chat?.shortName ?? line.entry.agents.first?.link.id ?? "")
        }
    }

    /// Fokus in der Triage, abgeglichen mit den Chats des gezeigten Tickets.
    var effectiveTriageFocus: TicketTriageFocus {
        triage == nil ? .list : TicketBoardSelection.reconcile(triageFocus, chatCount: chatLines.count)
    }

    /// Fokussierte Chat-Zeile oder `nil`.
    var focusedChatLine: Int? {
        if case .chat(let index) = effectiveTriageFocus { return index }
        return nil
    }

    /// Start-Auswahl, wenn der Controller das Board zum ersten Mal bedient:
    /// die Karte des Tickets, an dem `chatID` hängt; sonst die erste Karte der
    /// ersten Spalte, in der etwas wartet; sonst die erste Karte.
    func ensureControllerSelection(preferringChat chatID: UUID?) {
        guard triage == nil else { return }
        switch mode {
        case .board:
            guard TicketBoardSelection.place(of: boardSpot, in: boardColumns) == nil else { return }
            let preferred = chatID.flatMap { id in
                presentation.lanes.lazy.flatMap(\.entries).first { $0.agents.contains { $0.chat?.id == id } }?.ticket.key
            }
            let waitingColumn = presentation.lanes.first { lane in !lane.isFolded && lane.entries.contains(where: \.waitsForMe) }
            let waiting = waitingColumn.flatMap { TicketBoardLanes.shown($0, expanded: false).entries.first?.ticket.key }
            let start = TicketBoardSelection.controllerStart(preferred: preferred, waiting: waiting, in: boardColumns)
            setBoardSpot(start.map(TicketBoardSpot.card))
        case .list:
            guard listStop.map(listStops.contains) != true else { return }
            setListStop(listKeys.first ?? listStops.first)
        }
    }

    // MARK: Liste mit Gruppen (WM8-125)

    /// Stellen der Liste in Reihenfolge: der Kopf jeder Gruppe, darunter die
    /// Tickets aufgeklappter Gruppen. Köpfe als `group:<id>`, Tickets als Nummer.
    var listStops: [String] {
        presentation.groups.flatMap { group in
            [TicketListStop.group(group.id)] + (isCollapsed(group.id) ? [] : group.rows.map(\.id))
        }
    }

    /// Wo die Auswahl in der Liste steht: Kopf einer Gruppe oder Ticket.
    var listStop: String? { selectedGroupID.map(TicketListStop.group) ?? selectedKey }

    func setListStop(_ stop: String?) {
        if let id = stop.flatMap(TicketListStop.groupID) {
            if selectedGroupID != id { selectedGroupID = id }
        } else {
            if selectedGroupID != nil { selectedGroupID = nil }
            if selectedKey != stop { selectedKey = stop }
        }
    }

    // MARK: Befehle

    func controllerMove(_ direction: TicketBoardMove) -> ControllerTicketOutcome {
        if triage != nil {
            switch TicketBoardSelection.triageStep(effectiveTriageFocus, direction, chatCount: chatLines.count) {
            case .ticket(let step):
                guard let triage else { return .nothing }
                let moved = step > 0 ? TicketBoardSelection.next(triage) : TicketBoardSelection.previous(triage)
                // ▲ auf dem ersten Ticket der Liste: in den Kopf (Paket 3d).
                guard moved != triage else { return step < 0 ? .topEdge : .nothing }
                setTriage(moved)
                return .done
            case .focus(let focus):
                triageFocus = focus
                return .done
            case .edge(.left):
                return .leftEdge
            case .edge(.right):
                // Rechts aus der Liste (ohne Chats am Ticket) oder aus der
                // Chat-Zeile: weiter in den Board-Chat (Paket 3a).
                return .rightEdge
            case .edge:
                return .nothing
            }
        }
        switch mode {
        case .board:
            let step = TicketBoardSelection.step(boardSpot, direction, in: boardColumns)
            if step.edge == .left { return .leftEdge }
            if step.edge == .right { return .rightEdge }
            if step.edge == .top { return .topEdge }
            guard step.spot != boardSpot else { return .nothing }
            setBoardSpot(step.spot)
            return .done
        case .list:
            // Auf dem Kopf einer Gruppe: ◀ klappt zu, ▶ auf; erst am Rand geht es weiter.
            if let group = selectedGroupID, direction == .left || direction == .right {
                let collapsed = isCollapsed(group)
                if direction == .left, !collapsed { setGroup(group, collapsed: true); return .done }
                if direction == .right, collapsed { setGroup(group, collapsed: false); return .done }
            }
            let stop = listStop
            let step = TicketBoardSelection.stepInList(stop, direction, keys: listStops)
            if step.edge == .left { return .leftEdge }
            if step.edge == .right { return .rightEdge }
            if step.edge == .top { return .topEdge }
            guard step.key != stop else { return .nothing }
            setListStop(step.key)
            return .done
        }
    }

    /// Kreuz: auf dem Board und in der Liste das Ticket groß; auf der
    /// Chat-Zeile `chatLines[i]` (den Wechsel macht der Aufrufer).
    func controllerOpen() -> ControllerTicketOutcome {
        guard triage == nil else { return .rejected }
        switch mode {
        case .board:
            guard let key = TicketBoardSelection.openKey(boardSpot, in: boardColumns) else { return .rejected }
            openFromLane(key)
        case .list:
            if let group = selectedGroupID {
                // Kreuz bzw. Return auf dem Kopf einer Gruppe: auf- und zuklappen.
                toggleGroup(group)
                return .done
            }
            guard let key = selectedKey, listKeys.contains(key) else { return .rejected }
            openFromList(key)
        }
        return triage == nil ? .rejected : .done
    }

    /// Kreis in der Triage: von der Chat-Zeile in die Liste, aus der Liste
    /// zurück zum Board (Auswahl auf derselben Karte).
    func controllerBack() -> ControllerTicketOutcome {
        guard triage != nil else { return .rejected }
        if effectiveTriageFocus != .list {
            triageFocus = .list
            return .done
        }
        closeTriage()
        return .done
    }

    /// L1/R1: voriges oder nächstes Ticket. In der Triage durch ihre Liste,
    /// auf dem Board in Lesereihenfolge, in der Liste ihrer Reihe nach.
    func controllerAdjacent(_ step: Int) -> ControllerTicketOutcome {
        if let triage {
            let moved = step > 0 ? TicketBoardSelection.next(triage) : TicketBoardSelection.previous(triage)
            guard moved != triage else { return .nothing }
            setTriage(moved)
            return .done
        }
        switch mode {
        case .board:
            let next = TicketBoardSelection.adjacent(boardSpot, step, in: boardColumns)
            guard next.spot != boardSpot else { return .nothing }
            setBoardSpot(next.spot)
        case .list:
            let keys = listKeys
            guard !keys.isEmpty else { return .nothing }
            guard let key = selectedKey, let index = keys.firstIndex(of: key) else {
                selectedKey = keys.first
                return .done
            }
            let target = index + step
            guard keys.indices.contains(target) else { return .nothing }
            selectedKey = keys[target]
        }
        return .done
    }

    /// Chat, zu dem Kreuz auf der Chat-Zeile führt; `nil`, wenn er nicht auf
    /// diesem Rechner läuft.
    var focusedChatID: UUID? {
        guard let index = focusedChatLine, chatLines.indices.contains(index) else { return nil }
        return chatLines[index].chatID
    }

    /// Was der Controller über die Ansicht wissen muss.
    func controllerView(isReady: Bool) -> ControllerTicketView {
        // Der Kopf geht vor, auch bevor ein Stand da ist (Aktualisieren, Filter).
        if headerFocus != nil { return morePickerIndex == nil ? .header : .headerPicker }
        guard isReady else { return .empty }
        if triage != nil { return focusedChatLine == nil ? .triage : .chatLine }
        switch mode {
        case .board: return presentation.lanes.contains(where: { !$0.entries.isEmpty }) ? .board : .empty
        case .list: return presentation.groups.isEmpty ? .empty : .list
        }
    }
}

extension TicketBoardMove {
    init(_ direction: ControllerDirection) {
        switch direction {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        }
    }
}

/// Textansichten der Triage, schwach gehalten: Der Controller blättert mit dem
/// rechten Stick die des eigenen Fensters (WM8-91). Ohne Suche durch die
/// Ansichten des Fensters; es gibt je Fenster höchstens eine.
@MainActor
final class TicketTextScrollRegistry {
    static let shared = TicketTextScrollRegistry()
    private let views = NSHashTable<NSScrollView>.weakObjects()

    func register(_ scrollView: NSScrollView) {
        views.add(scrollView)
    }

    /// Blättert um `lines` Zeilen (positiv: nach unten). `false` ohne
    /// sichtbare Textansicht in diesem Fenster.
    func scroll(lines: Int, in window: NSWindow?) -> Bool {
        guard let window, let view = views.allObjects.first(where: { $0.window === window && !$0.isHiddenOrHasHiddenAncestor })
        else { return false }
        let clip = view.contentView
        let lineHeight: CGFloat = 18
        let maxY = max(0, (view.documentView?.frame.height ?? 0) - clip.bounds.height)
        let y = min(max(0, clip.bounds.origin.y + CGFloat(lines) * lineHeight), maxY)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        view.reflectScrolledClipView(clip)
        return true
    }
}
