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
        setTriage(TicketBoardSelection.open(key, keys: listKeys, source: .list,
                                            title: activeView?.name ?? String(localized: "List")))
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

    /// Text für die Mitte der Triage, nur wenn er zu diesem Ticket gehört.
    func document(for key: String) -> TicketDocument? {
        guard let document, document.ticketKey == key else { return nil }
        return document
    }

    /// Tasten aus dem Fenster (J/K, ↑↓, Esc). `false`: Die Taste gehört nicht
    /// der Triage, das Fenster reicht sie weiter.
    @discardableResult
    func handle(_ key: TicketBoardKey) -> Bool {
        if key == .copyLink { return copyLink() }
        guard triage != nil else { return false }
        switch key {
        case .next: nextInTriage()
        case .previous: previousInTriage()
        case .close: closeTriage()
        case .copyLink: break
        // Die übrigen Tasten nimmt das Fenster über `performTicketCommand`.
        default: return false
        }
        return true
    }

    // MARK: Kopieren

    /// Link des gewählten Tickets (in der Triage das gezeigte, auf dem Board
    /// die gewählte Karte). `false` ohne gewähltes Ticket: Dann gehört ⌘C
    /// wieder dem Fenster.
    @discardableResult
    func copyLink() -> Bool {
        guard let ticket = detail?.entry.ticket else { return false }
        copyToClipboard(TicketCopyText.link(ticket))
        noteCopied(.link)
        return true
    }

    /// Die gezeigten Tickets: in der Triage ihre Liste, auf dem Board alle
    /// Spalten nach Filter (auch, was unter „N weitere“ steht), in der Liste
    /// die Gruppen.
    func copyList(title: String) {
        copyToClipboard(listText(title: title))
        noteCopied(.list)
    }

    func listText(title: String) -> String {
        let sections: [TicketCopyText.Section]
        if let triage {
            sections = [TicketCopyText.Section(title: triage.title,
                                               tickets: triage.keys.compactMap { presentation.entry(key: $0)?.ticket })]
        } else if mode == .board {
            sections = presentation.lanes.map { TicketCopyText.Section(title: $0.status.name, tickets: $0.entries.map(\.ticket)) }
        } else {
            sections = presentation.groups.map {
                TicketCopyText.Section(title: $0.title, tickets: $0.entries.map(\.ticket))
            }
        }
        return TicketCopyText.list(title: title, sections: sections)
    }

    /// Tickets in der Reihenfolge der Liste, nur aus aufgeklappten Gruppen
    /// (J/K und die Liste der Triage überspringen zugeklappte, WM8-125).
    var listKeys: [String] {
        openGroups.flatMap { $0.rows.map(\.id) }
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
