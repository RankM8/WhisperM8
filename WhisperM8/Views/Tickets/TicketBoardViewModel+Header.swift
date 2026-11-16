import Foundation

/// Was der Kopf außer dem Modell kennen muss (Fenster).
struct TicketHeaderContext: Equatable {
    /// „← Chats“ steht im Kopf.
    var hasBack = true
    /// Ein Board-Chat ist sichtbar: „→ Jarvis“ steht im Kopf der Triage.
    var hasBoardChat = false
    /// Kopf der Board-Chat-Spalte rechts daneben (WM8-126); ▶ am rechten Ende
    /// einer Kopfzeile führt hinein. `nil`: keine Spalte (kein Projekt).
    var column: BoardChatHeadLayout?
}

/// Was ein Knopf im Kopf auslöst, das das Modell nicht selbst kann. Das
/// Fenster führt es aus (`performTicketCommand`).
enum TicketHeaderActivation: Equatable {
    /// Erledigt (Reiter, Board/Liste, Liste unter „Mehr“, Triage zu).
    case done
    case rejected
    case goBack
    case copyList
    case refresh
    case copyLink
    case handOff
    case openInLinear
}

/// Kopf und Reiter mit Controller und Tastatur (WM8-91 Paket 3d, WM8-125). Regeln pur
/// in `TicketHeaderSelection`; hier nur angewendet.
extension TicketBoardViewModel {
    func headerLayout(_ context: TicketHeaderContext) -> TicketHeaderLayout {
        if triage != nil {
            return .triage(hasBack: context.hasBack, hasBoardChat: context.hasBoardChat, hasURL: detail?.url != nil)
        }
        let tabs = tabs
        return .board(hasBack: context.hasBack, tabs: tabs.shown.map(\.id), hasMore: !tabs.more.isEmpty)
    }

    /// Knopf, auf dem die Auswahl im Kopf steht; für Ring und Leiste.
    func headerItem(_ context: TicketHeaderContext) -> TicketHeaderItem? {
        headerFocus.flatMap { headerLayout(context).item(at: $0) }
    }

    /// ▲ über die oberste Karte: in die unterste Kopfzeile, auf den zuletzt
    /// gewählten Knopf, falls es ihn dort noch gibt.
    @discardableResult
    func enterHeader(_ context: TicketHeaderContext) -> Bool {
        let layout = headerLayout(context)
        // Zuerst der zuletzt gewählte Knopf der Reiterzeile, sonst der gezeigte Reiter (WM8-125).
        let preferred = lastHeaderItem.flatMap { layout.rows.last?.contains($0) == true ? $0 : nil }
            ?? activeViewID.map(TicketHeaderItem.view)
        guard let spot = layout.entry(remembering: preferred) else { return false }
        morePickerIndex = nil
        leaveColumn()
        headerFocus = spot
        return true
    }

    /// Zurück auf die Karte (▼ unter der untersten Zeile, Kreis).
    func leaveHeader() {
        morePickerIndex = nil
        headerFocus = nil
        leaveColumn()
    }

    /// Stick und Steuerkreuz im Kopf bzw. in der Liste unter „Mehr“. Bewegen
    /// wählt nur aus; geschaltet wird mit Kreuz.
    func headerMove(_ direction: TicketBoardMove, _ context: TicketHeaderContext) -> ControllerTicketOutcome {
        if let index = morePickerIndex {
            let next = TicketHeaderSelection.pickerStep(index, direction, count: tabs.more.count)
            guard next != index else { return .nothing }
            morePickerIndex = next
            return .done
        }
        guard let spot = headerFocus else { return .nothing }
        let layout = headerLayout(context)
        switch TicketHeaderSelection.step(spot, direction, in: layout) {
        case .spot(let next):
            headerFocus = next
            if let item = layout.item(at: next) { lastHeaderItem = item }
            return .done
        case .stay:
            // ▶ am rechten Ende einer Zeile: weiter in den Kopf der Spalte (WM8-126).
            if direction == .right, let column = context.column, enterColumn(column, from: spot) { return .done }
            return .nothing
        case .leave:
            leaveHeader()
            return .done
        }
    }

    /// Kreuz im Kopf: schaltet den Knopf. In der Liste unter „Mehr“: zeigt
    /// die gewählte Ansicht und schließt die Liste.
    func headerActivate(_ context: TicketHeaderContext) -> TicketHeaderActivation {
        if let index = morePickerIndex {
            let more = tabs.more
            morePickerIndex = nil
            guard more.indices.contains(index) else { return .rejected }
            selectView(more[index].id)
            lastHeaderItem = .view(more[index].id)
            reconcileHeader(context)
            return .done
        }
        guard let item = headerItem(context) else { return .rejected }
        lastHeaderItem = item
        switch item {
        case .back: return .goBack
        case .modeBoard: mode = .board
        case .modeList: mode = .list
        case .copyList: return .copyList
        case .refresh: return .refresh
        case .closeTriage:
            closeTriage()
            return .done
        case .copyLink: return .copyLink
        case .handOff: return .handOff
        case .openInLinear: return .openInLinear
        case .view(let id): selectView(id)
        case .moreViews:
            let more = tabs.more
            guard !more.isEmpty else { return .rejected }
            morePickerIndex = more.firstIndex { $0.id == activeViewID } ?? 0
        }
        reconcileHeader(context)
        return .done
    }

    /// Mausklick auf einen Eintrag unter „Mehr“: zeigt die Ansicht und räumt
    /// den Kopf, denn die Maus hat übernommen. Wirkt beim Mausdruck (WM8-91):
    /// Das Räumen nach jedem Klick (`TicketBoardControllers`) kann schon gelaufen
    /// sein. Ein Reiter schreibt nichts nach Linear.
    func chooseMoreViewByMouse(_ id: String) {
        selectView(id)
        leaveHeader()
    }

    /// Kreis: Liste unter „Mehr“ zu (ohne Änderung), sonst zurück auf die Karte.
    func headerBack() {
        if morePickerIndex != nil {
            morePickerIndex = nil
        } else {
            leaveHeader()
        }
    }

    /// Nach einem Reiterwechsel kann ein anderer Reiter unter „Mehr“ rutschen:
    /// Die Auswahl bleibt auf demselben Knopf oder rückt in der Zeile nach.
    private func reconcileHeader(_ context: TicketHeaderContext) {
        guard let spot = headerFocus else { return }
        let layout = headerLayout(context)
        if let item = lastHeaderItem, let row = layout.rows.firstIndex(where: { $0.contains(item) }),
           let index = layout.rows[row].firstIndex(of: item) {
            headerFocus = TicketHeaderSpot(row: row, index: index)
        } else {
            headerFocus = layout.reconcile(spot)
        }
    }
}
