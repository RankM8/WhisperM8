import Foundation

/// Was ein Knopf im Kopf der Board-Chat-Spalte auslöst. Das Modell kennt
/// weder Fenster noch die gespeicherte Wahl; das Fenster führt es aus.
enum BoardChatHeadActivation: Equatable {
    /// Erledigt (Liste auf oder zu, gewählter Chat erneut: nichts zu tun).
    case done
    case rejected
    /// Diesen Chat als Board-Chat zeigen (Knopf oder Eintrag der Liste).
    case choose(UUID)
    case openAsTab
    case hide
    case show
}

/// Was ▼ im Kopf der Spalte bedeutet; entscheidet das Fenster je nachdem,
/// ob dort ein Terminal steht.
enum BoardChatHeadExit: Equatable {
    /// In den Board-Chat, mit Ankunftssperre (wie ▶ am rechten Rand).
    case intoBoardChat
    /// Zurück auf die Karte bzw. das Ticket.
    case toBoard
}

/// Kopf der Board-Chat-Spalte mit Controller und Tastatur (WM8-126). Regeln
/// pur in `BoardChatHeadSelection`; hier nur angewendet.
extension TicketBoardViewModel {
    /// ▶ am rechten Ende einer Kopfzeile des Boards. `spot`: Stelle im Kopf
    /// des Boards, zu der ◀ zurückführt.
    @discardableResult
    func enterColumn(_ layout: BoardChatHeadLayout, from spot: TicketHeaderSpot?) -> Bool {
        guard let item = BoardChatHeadSelection.entry(layout, remembering: lastColumnItem) else { return false }
        // Kopf des Boards samt seiner Liste räumen (`leaveHeader`), dann hierher.
        leaveHeader()
        columnReturn = spot
        columnFocus = item
        lastColumnItem = item
        return true
    }

    /// Auswahl und Liste der Spalte weg (Maus, Tickets zu, Kopf verlassen).
    func leaveColumn() {
        if columnFocus != nil { columnFocus = nil }
        if columnPickerIndex != nil { columnPickerIndex = nil }
    }

    /// Stick und Steuerkreuz im Kopf der Spalte bzw. in der Liste. Bewegen
    /// wählt nur aus. `exit` beantwortet ▼ (Fenster: Terminal hier oder nicht).
    func columnMove(_ direction: TicketBoardMove, _ context: TicketHeaderContext,
                    exit: BoardChatHeadExit) -> ControllerTicketOutcome {
        guard let layout = context.column else {
            leaveColumn()
            return .rejected
        }
        if let index = columnPickerIndex {
            let next = BoardChatHeadSelection.pickerStep(index, direction, count: layout.others.count)
            guard next != index else { return .nothing }
            columnPickerIndex = next
            return .done
        }
        guard let item = columnFocus else { return .nothing }
        switch BoardChatHeadSelection.step(item, direction, in: layout) {
        case .item(let next):
            columnFocus = next
            lastColumnItem = next
            return .done
        case .stay:
            return .nothing
        case .backToBoardHeader:
            leaveColumn()
            let board = headerLayout(context)
            headerFocus = columnReturn.flatMap { board.reconcile($0) } ?? board.entry(remembering: lastHeaderItem)
            return .done
        case .down:
            leaveColumn()
            headerFocus = nil
            // In den Board-Chat übernimmt der Ausführer (`.rightEdge`): mit
            // Ankunftssperre, nur solange er sichtbar ist.
            return exit == .intoBoardChat ? .rightEdge : .done
        }
    }

    /// Kreuz im Kopf der Spalte. In der Liste: übernimmt den gewählten Chat
    /// und schließt sie. Nichts davon schreibt in einen Chat.
    func columnActivate(_ context: TicketHeaderContext) -> BoardChatHeadActivation {
        guard let layout = context.column else {
            leaveColumn()
            return .rejected
        }
        if let index = columnPickerIndex {
            columnPickerIndex = nil
            guard layout.others.indices.contains(index) else { return .rejected }
            return .choose(layout.others[index].id)
        }
        guard let item = columnFocus, layout.items.contains(item) else { return .rejected }
        lastColumnItem = item
        switch item {
        case .choice(let id):
            // Der Chat steht schon in der Spalte: Kreuz tut nichts (führt
            // nie in ihn hinein, nur ▼ tut das, mit Ankunftssperre).
            return id == layout.current ? .done : .choose(id)
        case .otherChat:
            guard !layout.others.isEmpty else { return .rejected }
            columnPickerIndex = 0
            return .done
        case .openAsTab: return .openAsTab
        case .hide: return .hide
        case .show: return .show
        }
    }

    /// Kreis: Liste zu (ohne Wahl), sonst zurück auf die Karte.
    func columnBack() {
        if columnPickerIndex != nil {
            columnPickerIndex = nil
        } else {
            leaveHeader()
        }
    }

    /// Nach einer Wahl, Zu- oder Aufklappen hat der Kopf andere Knöpfe: Die
    /// Auswahl bleibt auf demselben Knopf oder geht auf den Einstieg.
    /// `chosen`: der eben gewählte Chat, auf dem der Ring stehen soll.
    func reconcileColumn(_ layout: BoardChatHeadLayout?, chosen: UUID? = nil) {
        guard let item = columnFocus else { return }
        guard let layout else { return leaveColumn() }
        if let chosen, layout.items.contains(.choice(chosen)) {
            columnFocus = .choice(chosen)
        } else {
            columnFocus = BoardChatHeadSelection.reconcile(item, in: layout)
        }
        lastColumnItem = columnFocus
        if columnPickerIndex != nil, !layout.items.contains(.otherChat) { columnPickerIndex = nil }
    }

    /// Mausklick auf „Anderer Chat …“: Liste auf. Der Ring steht dann auf dem
    /// Knopf, damit es dieselbe Liste ist wie am Controller. Zu geht sie mit
    /// einem Klick daneben (`TicketBoardControllers.leaveHeaders`), Esc oder
    /// einer Wahl. Kein Umschalten: Der Klick daneben räumt schon beim
    /// Mausdruck, ein Umschalten beim Loslassen öffnete sie gleich wieder.
    func openOtherChatsByMouse(hasOptions: Bool) {
        guard hasOptions else { return }
        leaveHeader()
        columnFocus = .otherChat
        lastColumnItem = .otherChat
        columnPickerIndex = 0
    }
}
