import Foundation
import Observation

// MARK: - Was die Ticket-Ansicht zeigt

/// Fertig gerechneter Inhalt der Ansicht: Spalten, Backlog-Gruppen, Zahlen für
/// die Filter. Pur und vergleichbar; die Ansichten zeichnen nur.
struct TicketBoardPresentation: Equatable {
    struct Group: Equatable, Identifiable {
        /// Name des Projekts; `""` für Tickets ohne Projekt.
        var project: String
        var entries: [TicketBoardEntry]

        var id: String { project }
        var agentCount: Int { entries.filter(\.hasAgent).count }
    }

    var columns: [TicketBoardColumn]
    /// Backlog-Liste: alle sichtbaren Tickets nach Projekt.
    var groups: [Group]
    var counts: TicketFilterCounts
    /// Projekte zur Auswahl, alphabetisch; `""` (ohne Projekt) steht am Ende.
    var projects: [String]
    var looseChats: [TicketLooseChat]
    var visibleCount: Int

    /// Ohne Abzug: drei leere Spalten, keine Gruppen.
    static let empty = make(model: TicketBoardModel(entries: [], looseChats: [], supervisors: []), filter: .all)

    static func make(model: TicketBoardModel, filter: TicketBoardFilter) -> TicketBoardPresentation {
        // Erledigte Tickets stehen nur für die Spur „zuletzt an …“ im Abzug.
        let open = model.entries.filter { !$0.ticket.status.kind.isClosed }
        let visible = filter.apply(to: open)
        var byProject: [String: [TicketBoardEntry]] = [:]
        for entry in visible { byProject[entry.ticket.project ?? "", default: []].append(entry) }
        let names = Set(open.map { $0.ticket.project ?? "" })
        return TicketBoardPresentation(
            columns: TicketBoardLayout.columns(visible),
            groups: sorted(Array(byProject.keys)).map { Group(project: $0, entries: byProject[$0, default: []].sorted(by: TicketBoardLayout.order)) },
            counts: TicketFilterCounts.make(entries: open, filter: filter),
            projects: sorted(Array(names)),
            looseChats: model.looseChats,
            visibleCount: visible.count)
    }

    func entry(key: String?) -> TicketBoardEntry? {
        guard let key else { return nil }
        return groups.lazy.flatMap(\.entries).first { $0.ticket.key == key }
    }

    private static func sorted(_ projects: [String]) -> [String] {
        projects.sorted { lhs, rhs in
            if lhs.isEmpty != rhs.isEmpty { return rhs.isEmpty }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
}

// MARK: - Zustand der Ansicht

/// Auswahl und Filter der Ticket-Ansicht. Rechnet den Inhalt neu, wenn sich
/// der Abzug oder ein Filter ändert, nie beim Zeichnen.
@MainActor
@Observable
final class TicketBoardViewModel {
    enum Mode: Equatable {
        case board
        case backlog
    }

    var mode: Mode = .board
    var filter = TicketBoardFilter() {
        didSet { if filter != oldValue { rebuild() } }
    }
    var selectedKey: String? {
        didSet { if selectedKey != oldValue { refreshSelection() } }
    }

    private(set) var presentation: TicketBoardPresentation = .empty
    /// Das gewählte Ticket und seine zerlegte Beschreibung. Gerechnet beim
    /// Wählen und bei einem neuen Abzug, nicht beim Zeichnen.
    private(set) var selected: TicketBoardEntry?
    private(set) var selectedDescription: [TicketDescriptionBlock] = []
    @ObservationIgnored private var model = TicketBoardModel(entries: [], looseChats: [], supervisors: [])

    init(model: TicketBoardModel? = nil) {
        if let model { update(model) }
    }

    /// Neuer Abzug oder geänderte Chats.
    func update(_ model: TicketBoardModel) {
        guard model != self.model else { return }
        self.model = model
        // Ein gewähltes Projekt, das es nicht mehr gibt, würde alles ausblenden.
        if let project = filter.project, !model.entries.contains(where: { ($0.ticket.project ?? "") == project }) {
            filter.project = nil   // löst den Neuaufbau über `didSet` aus
        }
        rebuild()
        // Ein Ticket, das der Filter ausblendet, bleibt gewählt; eines, das es nicht mehr gibt, nicht.
        if let key = selectedKey, !model.entries.contains(where: { $0.ticket.key == key }) { selectedKey = nil }
    }

    func toggle(_ key: String) {
        selectedKey = selectedKey == key ? nil : key
    }

    private func rebuild() {
        let fresh = TicketBoardPresentation.make(model: model, filter: filter)
        if fresh != presentation { presentation = fresh }
        refreshSelection()
    }

    private func refreshSelection() {
        let entry = presentation.entry(key: selectedKey)
        // Die Beschreibung nur neu zerlegen, wenn sich ihr Text geändert hat.
        if entry?.ticket.description != selected?.ticket.description {
            selectedDescription = entry.map { TicketDescriptionBlocks.make($0.ticket.description) } ?? []
        }
        if entry != selected { selected = entry }
    }
}

// MARK: - Live-Zustand der Chats

/// Zustand der Chats für die Status-Punkte. Nur die Punkte lesen hier; ein
/// Statuswechsel baut deshalb weder Karten noch Board neu auf.
@MainActor
@Observable
final class TicketChatStatusSource {
    var states: [UUID: TicketChatState]

    init(states: [UUID: TicketChatState] = [:]) {
        self.states = states
    }
}

extension TicketChatState {
    /// Für den gemeinsamen Status-Punkt der App.
    var runtimeStatus: AgentSessionRuntimeStatus {
        switch self {
        case .working: return .working
        case .needsYou: return .awaitingInput
        case .idle: return .idle
        case .errored: return .errored
        case .stopped: return .stopped
        }
    }
}
