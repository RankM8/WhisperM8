import Foundation

/// Was der Kopf außer dem Modell kennen muss (Fenster).
struct TicketHeaderContext: Equatable {
    /// „← Chats“ steht im Kopf.
    var hasBack = true
    /// Ein Board-Chat ist sichtbar: „→ Jarvis“ steht im Kopf der Triage.
    var hasBoardChat = false
}

/// Was ein Knopf im Kopf auslöst, das das Modell nicht selbst kann. Das
/// Fenster führt es aus (`performTicketCommand`).
enum TicketHeaderActivation: Equatable {
    /// Erledigt (Filter, Board/Liste, Liste der Bereiche, Triage zu).
    case done
    case rejected
    case goBack
    case copyList
    case refresh
    case copyLink
    case handOff
    case openInLinear
}

/// Kopf und Filter mit Controller und Tastatur (WM8-91 Paket 3d). Regeln pur
/// in `TicketHeaderSelection`; hier nur angewendet.
extension TicketBoardViewModel {
    func headerLayout(_ context: TicketHeaderContext) -> TicketHeaderLayout {
        if triage != nil {
            return .triage(hasBack: context.hasBack, hasBoardChat: context.hasBoardChat, hasURL: detail?.url != nil)
        }
        return .board(hasBack: context.hasBack,
                      people: presentation.counts.people.map { .person(id: $0.person.id) })
    }

    /// Knopf, auf dem die Auswahl im Kopf steht; für Ring und Leiste.
    func headerItem(_ context: TicketHeaderContext) -> TicketHeaderItem? {
        headerFocus.flatMap { headerLayout(context).item(at: $0) }
    }

    /// ▲ über die oberste Karte: in die unterste Kopfzeile, auf den zuletzt
    /// gewählten Knopf, falls es ihn dort noch gibt.
    @discardableResult
    func enterHeader(_ context: TicketHeaderContext) -> Bool {
        guard let spot = headerLayout(context).entry(remembering: lastHeaderItem) else { return false }
        projectPickerIndex = nil
        headerFocus = spot
        return true
    }

    /// Zurück auf die Karte (▼ unter der untersten Zeile, Kreis).
    func leaveHeader() {
        projectPickerIndex = nil
        headerFocus = nil
    }

    /// Stick und Steuerkreuz im Kopf bzw. in der Liste der Bereiche. Bewegen
    /// wählt nur aus; geschaltet wird mit Kreuz.
    func headerMove(_ direction: TicketBoardMove, _ context: TicketHeaderContext) -> ControllerTicketOutcome {
        if let index = projectPickerIndex {
            let next = TicketHeaderSelection.projectStep(
                index, direction, count: TicketHeaderSelection.projectOptions(presentation.projects).count)
            guard next != index else { return .nothing }
            projectPickerIndex = next
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
            return .nothing
        case .leave:
            leaveHeader()
            return .done
        }
    }

    /// Kreuz im Kopf: schaltet den Knopf. In der Liste der Bereiche: übernimmt
    /// den gewählten Bereich und schließt sie.
    func headerActivate(_ context: TicketHeaderContext) -> TicketHeaderActivation {
        if let index = projectPickerIndex {
            let options = TicketHeaderSelection.projectOptions(presentation.projects)
            projectPickerIndex = nil
            guard options.indices.contains(index) else { return .rejected }
            filter.project = options[index]
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
        case .waitingForMe: filter.waitingForMe.toggle()
        case .project:
            projectPickerIndex = TicketHeaderSelection.projectStart(
                current: filter.project, options: TicketHeaderSelection.projectOptions(presentation.projects))
        case .agent(let agent): filter.agent = agent
        case .person(let person): filter.person = person
        }
        reconcileHeader(context)
        return .done
    }

    /// Kreis: Liste der Bereiche zu (ohne Änderung), sonst zurück auf die Karte.
    func headerBack() {
        if projectPickerIndex != nil {
            projectPickerIndex = nil
        } else {
            leaveHeader()
        }
    }

    /// Nach einem Filter können Personen wegfallen: Die Auswahl bleibt auf
    /// demselben Knopf oder rückt in der Zeile nach.
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
