import AppKit
import Foundation

/// Fertiger Text des gezeigten Tickets für die Mitte der Triage.
struct TicketDocument {
    var ticketKey: String
    var revision: Int
    var text: NSAttributedString
}

/// Wie der Text gebaut wird: in der App abseits des Main Threads, in Bildern
/// und Tests sofort.
enum TicketDocumentBuilding {
    case background
    case immediate
}

// MARK: - Triage: öffnen, blättern, schließen

/// Die Regeln stehen in `TicketBoardSelection`; hier werden sie auf den
/// Zustand der Ansicht angewendet.
extension TicketBoardViewModel {
    /// Klick auf eine Karte: Triage mit der Spalte als Liste.
    func openFromLane(_ key: String) {
        guard let lane = presentation.lanes.first(where: { $0.entries.contains { $0.ticket.key == key } }) else { return }
        setTriage(TicketBoardSelection.open(key, keys: lane.entries.map(\.ticket.key), source: .lane(statusID: lane.id),
                                            title: lane.status.name))
    }

    /// Klick in der Liste: Triage mit allen sichtbaren Tickets der Liste.
    func openFromList(_ key: String) {
        setTriage(TicketBoardSelection.open(key, keys: listKeys, source: .list, title: String(localized: "List")))
    }

    func nextInTriage() {
        guard let triage else { return }
        setTriage(TicketBoardSelection.next(triage))
    }

    func previousInTriage() {
        guard let triage else { return }
        setTriage(TicketBoardSelection.previous(triage))
    }

    func selectInTriage(_ key: String) {
        guard let triage else { return }
        setTriage(TicketBoardSelection.select(key, in: triage))
    }

    /// Zurück zum Board; die Karte des zuletzt gezeigten Tickets bleibt gewählt.
    func closeTriage() {
        guard let triage else { return }
        let key = TicketBoardSelection.close(triage)
        setTriage(nil)
        selectedKey = key
    }

    /// Ein Schritt der Auswahl auf dem Board (Steuerkreuz, Pfeile; WM8-91).
    /// Ohne offene Triage; gerechnet in `TicketBoardSelection.move`.
    func moveOnBoard(_ direction: TicketBoardMove) {
        guard triage == nil, mode == .board else { return }
        let columns = TicketBoardSelection.columns(presentation.lanes)
        if let key = TicketBoardSelection.move(selectedKey, direction, in: columns), key != selectedKey { selectedKey = key }
    }

    /// Die gewählte Karte groß öffnen (Return, Kreuz).
    func openSelected() {
        guard triage == nil, let key = selectedKey else { return }
        switch mode {
        case .board: openFromLane(key)
        case .list: openFromList(key)
        }
    }

    /// Tasten aus dem Fenster (J/K, ↑↓, Esc). `false`: Die Taste gehört nicht
    /// der Triage, das Fenster reicht sie weiter.
    @discardableResult
    func handle(_ key: TicketBoardKey) -> Bool {
        guard triage != nil else { return false }
        switch key {
        case .next: nextInTriage()
        case .previous: previousInTriage()
        case .close: closeTriage()
        }
        return true
    }

    /// Liste der Tickets in der Reihenfolge der Liste (nach Projekt).
    var listKeys: [String] {
        presentation.groups.flatMap { $0.entries.map(\.ticket.key) }
    }

    /// Schlüssel der Quelle nach einem neuen Abzug.
    func keys(for source: TicketTriageSource) -> [String] {
        switch source {
        case .list:
            return listKeys
        case .lane(let statusID):
            return presentation.lanes.first { $0.id == statusID }?.entries.map(\.ticket.key) ?? []
        }
    }
}
