import Combine
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
    var supervisors: [TicketChat]
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
            supervisors: model.supervisors,
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
    /// Alles, was das Detail zum gewählten Ticket zeigt. Gerechnet beim Wählen
    /// und bei einem neuen Abzug, nicht beim Zeichnen.
    private(set) var detail: TicketDetailContent?

    var selected: TicketBoardEntry? { detail?.entry }
    var selectedDescription: [TicketDescriptionBlock] { detail?.description ?? [] }
    @ObservationIgnored private var model = TicketBoardModel(entries: [], looseChats: [], supervisors: [])
    /// Wie oft der Inhalt neu gerechnet wurde (für Tests).
    @ObservationIgnored private(set) var rebuilds = 0

    init(model: TicketBoardModel? = nil) {
        if let model { update(model) }
    }

    /// Neuer Abzug oder geänderte Chats. Der Zustand der Chats zählt hier nicht:
    /// Den führt die `TicketChatStatusSource`, damit ein Statuswechsel nichts
    /// neu rechnet.
    func update(_ fresh: TicketBoardModel) {
        let model = fresh.withoutChatStates
        guard model != self.model else { return }
        self.model = model
        // Ein Filter auf etwas, das es nicht mehr gibt, würde alles ausblenden.
        var filter = filter
        if let project = filter.project, !model.entries.contains(where: { ($0.ticket.project ?? "") == project }) {
            filter.project = nil
        }
        if case .person(let id) = filter.person, !model.entries.contains(where: { $0.ticket.assignee?.id == id }) {
            filter.person = .all
        }
        if filter != self.filter {
            self.filter = filter   // baut über `didSet` neu
        } else {
            rebuild()
        }
        // Ein Ticket, das der Filter ausblendet, bleibt gewählt; eines, das es nicht mehr gibt, nicht.
        if let key = selectedKey, !model.entries.contains(where: { $0.ticket.key == key }) { selectedKey = nil }
    }

    func toggle(_ key: String) {
        selectedKey = selectedKey == key ? nil : key
    }

    /// Anderes Projekt oder Team: Filter und Auswahl gehören zum alten.
    func reset() {
        selectedKey = nil
        mode = .board
        model = TicketBoardModel(entries: [], looseChats: [], supervisors: [])
        if filter != TicketBoardFilter() { filter = TicketBoardFilter() } else { rebuild() }
    }

    private func rebuild() {
        rebuilds += 1
        let fresh = TicketBoardPresentation.make(model: model, filter: filter)
        if fresh != presentation { presentation = fresh }
        refreshSelection()
    }

    private func refreshSelection() {
        guard let entry = presentation.entry(key: selectedKey) else {
            if detail != nil { detail = nil }
            return
        }
        guard entry != detail?.entry else { return }
        // Die Beschreibung nur neu zerlegen, wenn sich ihr Text geändert hat.
        let description = entry.ticket.description == detail?.entry.ticket.description
            ? detail?.description ?? [] : TicketDescriptionBlocks.make(entry.ticket.description)
        detail = TicketDetailContent.make(entry, description: description)
    }
}

// MARK: - Inhalt des Details

/// Was das Detail zeigt, fertig abgeleitet: die Zeilen der Chats mit ihrer
/// Zeitangabe, der Chat für „Zum Chat“ und die geprüfte Adresse.
struct TicketDetailContent: Equatable {
    struct AgentLine: Equatable, Identifiable {
        var id: String
        /// Eintrag mit genau diesem Chat, für die gemeinsame Zeile.
        var entry: TicketBoardEntry
        var since: Date?
    }

    var entry: TicketBoardEntry
    var description: [TicketDescriptionBlock]
    var agents: [AgentLine]
    /// Der erste Chat, der auf diesem Rechner läuft.
    var localChatID: UUID?
    /// Adresse im Ticket-Werkzeug; nur `https`.
    var url: URL?

    static func make(_ entry: TicketBoardEntry, description: [TicketDescriptionBlock]) -> TicketDetailContent {
        let url = entry.ticket.url.flatMap(URL.init(string:)).flatMap { $0.scheme?.lowercased() == "https" && $0.host != nil ? $0 : nil }
        return TicketDetailContent(
            entry: entry, description: description,
            agents: entry.agents.map { AgentLine(id: $0.link.id, entry: TicketBoardEntry(ticket: entry.ticket, agents: [$0]), since: $0.link.since) },
            localChatID: entry.agents.lazy.compactMap(\.chat).first?.id,
            url: url)
    }
}

// MARK: - Live-Zustand der Chats

/// Woher die Status-Punkte den Zustand eines Chats bekommen. Jeder Punkt hört
/// nur auf seinen Chat: Ein Statuswechsel zeichnet genau einen Punkt neu,
/// keine Karte und kein Board. In der App ist das der Laufzeit-Speicher der
/// Chats (`AgentSessionRuntimeStatusStore`), nicht der Aktivitäts-Speicher der
/// Seitenleiste.
struct TicketChatStatusSource {
    /// Zustand jetzt, für das erste Zeichnen.
    var current: @MainActor (UUID) -> AgentSessionRuntimeStatus?
    /// Änderungen dieses einen Chats.
    var changes: @MainActor (UUID) -> AnyPublisher<AgentSessionRuntimeStatus?, Never>

    @MainActor static let live = TicketChatStatusSource(
        current: { AgentSessionStatusCoordinator.shared.statusStore.status(for: $0) },
        changes: { AgentSessionStatusCoordinator.shared.statusStore.statusPublisher(for: $0) }
    )

    /// Feste Zustände für Snapshots und Tests.
    static func fixed(_ states: [UUID: TicketChatState]) -> TicketChatStatusSource {
        TicketChatStatusSource(
            current: { states[$0]?.runtimeStatus },
            changes: { _ in Empty().eraseToAnyPublisher() })
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
