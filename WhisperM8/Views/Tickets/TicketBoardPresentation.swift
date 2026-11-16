import AppKit
import Combine
import Foundation
import Observation

// MARK: - Was die Ticket-Ansicht zeigt

/// Fertig gerechneter Inhalt der Ansicht: Spalten, Backlog-Gruppen, Zahlen für
/// die Filter. Pur und vergleichbar; die Ansichten zeichnen nur.
struct TicketBoardPresentation: Equatable {
    /// Eine Spalte je Status des Teams.
    var lanes: [TicketBoardLane]
    /// Liste: die sichtbaren Tickets in den Gruppen der Ansicht (WM8-125).
    var groups: [TicketListGroup]
    /// Ansicht, nach der gruppiert ist; `nil` = alle offenen Tickets nach Status.
    var view: TicketView?
    var counts: TicketFilterCounts
    /// Projekte zur Auswahl, alphabetisch; `""` (ohne Projekt) steht am Ende.
    var projects: [String]
    var looseChats: [TicketLooseChat]
    var supervisors: [TicketChat]
    var visibleCount: Int
    /// Regel des Teams; die Karten heben ihre Labels für „wartet auf mich“ hervor.
    var rule: TicketTeamRule
    /// Nachschlag Ticket-Nummer → Stelle in `groups`; zählt nicht zum Vergleich.
    var keyIndex = TicketKeyIndex()

    /// Ohne Abzug: drei leere Spalten, keine Gruppen.
    static let empty = make(model: TicketBoardModel(entries: [], looseChats: [], supervisors: []), filter: .all)

    static func make(model: TicketBoardModel, filter: TicketBoardFilter) -> TicketBoardPresentation {
        // Erledigte Tickets stehen nur für die Spur „zuletzt an …“ im Abzug.
        let open = model.entries.filter { !$0.ticket.status.kind.isClosed }
        let visible = filter.apply(to: open)
        let names = Set(open.map { $0.ticket.project ?? "" })
        return TicketBoardPresentation(
            lanes: TicketBoardLanes.make(statuses: model.statuses, open: open, visible: visible, rule: model.rule,
                                         filterActive: filter != .all),
            groups: TicketListGrouping.make(entries: visible, view: model.view, rule: model.rule),
            view: model.view,
            counts: TicketFilterCounts.make(entries: open, filter: filter),
            projects: sorted(Array(names)),
            looseChats: model.looseChats,
            supervisors: model.supervisors,
            visibleCount: visible.count,
            rule: model.rule)
            .indexed()
    }

    func entry(key: String?) -> TicketBoardEntry? {
        guard let key, let index = indexByKey[key] else { return nil }
        let (group, row) = index
        return groups[group].rows[row].entry
    }

    /// Wo ein Ticket in `groups` steht. Die Liste der Triage fragt je Zeile
    /// nach; ein Durchsuchen aller Gruppen wäre je Zeichnen quadratisch.
    private var indexByKey: [String: (Int, Int)] {
        // Einmal je Präsentation gerechnet, siehe `make`.
        keyIndex.storage
    }

    private func indexed() -> TicketBoardPresentation {
        var copy = self
        var storage: [String: (Int, Int)] = [:]
        for (g, group) in groups.enumerated() {
            for (r, row) in group.rows.enumerated() { storage[row.entry.ticket.key] = (g, r) }
        }
        copy.keyIndex = TicketKeyIndex(storage: storage)
        return copy
    }

    private static func sorted(_ projects: [String]) -> [String] {
        projects.sorted { lhs, rhs in
            if lhs.isEmpty != rhs.isEmpty { return rhs.isEmpty }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
}

/// Abgeleiteter Nachschlag; gleich, wenn die Gruppen gleich sind.
struct TicketKeyIndex: Equatable {
    var storage: [String: (Int, Int)] = [:]
    static func == (lhs: TicketKeyIndex, rhs: TicketKeyIndex) -> Bool { true }
}

// MARK: - Zustand der Ansicht

/// Auswahl und Filter der Ticket-Ansicht. Rechnet den Inhalt neu, wenn sich
/// der Abzug oder ein Filter ändert, nie beim Zeichnen.
@MainActor
@Observable
final class TicketBoardViewModel {
    enum Mode: Equatable {
        case board
        case list
    }

    /// Liste ist der Standard (Giuliano, 16.11.2026, WM8-125); das Board bleibt umschaltbar.
    var mode: Mode = .list {
        didSet { if mode != oldValue { onControllerViewChange?() } }
    }
    /// Reiter aus Linear (WM8-125); leer, solange nicht geladen oder ohne Ansichten.
    /// Die vier Werte hier setzt nur `TicketBoardViewModel+Views` (`setViews`,
    /// `selectView`, `setGroup`); sie stehen dort in einer eigenen Datei.
    var catalog = TicketViewCatalog.empty
    /// Gezeigter Reiter; `nil`, solange es keine Ansichten gibt.
    var activeViewID: String?
    /// Die gezeigte Ansicht lädt noch (erster Abruf ihrer Tickets).
    var isViewLoading = false
    /// Zugeklappte Gruppen, je Ansicht (`<Ansicht>|<Gruppe>`). Gilt je Fenster, nicht gespeichert.
    var collapsedGroups: Set<String> = []
    /// Ein anderer Reiter wurde gewählt; der Controller holt seine Tickets.
    @ObservationIgnored var onSelectView: ((String) -> Void)?
    /// Controller und Tastatur (WM8-91 Paket 3d): Auswahl im Kopf; `nil` =
    /// auf den Karten. Board und Karten behalten ihre Auswahl darunter.
    var headerFocus: TicketHeaderSpot?
    /// Liste unter „Mehr“ offen (WM8-125): gewählter Eintrag.
    var morePickerIndex: Int?
    /// Breite der Reiterzeile, von der Ansicht gemessen; daraus folgt, was
    /// unter „Mehr“ steht. Nur bei echter Änderung gesetzt.
    var tabsWidth: CGFloat?
    /// Zuletzt gewählter Knopf der Filterzeile: Dort steigt ▲ wieder ein.
    @ObservationIgnored var lastHeaderItem: TicketHeaderItem?
    /// Controller und Tastatur (WM8-126): Auswahl im Kopf der Board-Chat-
    /// Spalte; `nil` = nicht dort. Steht sie dort, ist `headerFocus` leer.
    var columnFocus: BoardChatHeadItem?
    /// Liste unter „Anderer Chat …“ offen: gewählter Eintrag.
    var columnPickerIndex: Int?
    /// Stelle im Kopf des Boards, von der ▶ in die Spalte führte; ◀ geht dorthin zurück.
    @ObservationIgnored var columnReturn: TicketHeaderSpot?
    @ObservationIgnored var lastColumnItem: BoardChatHeadItem?
    /// Ansicht gewechselt (Board/Liste, Triage auf/zu), auch per Maus: Die
    /// Leiste des Controllers liest dann neu (WM8-91, Befund vom 16.11.2026).
    @ObservationIgnored var onControllerViewChange: (@MainActor () -> Void)?
    /// Fenster dieser Ansicht; daran hängt der Board-Chat (WM8-113). `nil` in Bildern und Tests.
    @ObservationIgnored var windowID: UUID?
    var selectedKey: String? {
        didSet {
            if selectedKey != oldValue { refreshSelection() }
            // Eine Karte gewählt (Maus, Tastatur, Controller): weg von „N weitere“ (WM8-91).
            if moreColumn != nil, selectedKey != nil { moreColumn = nil }
            // Und weg vom Kopf einer Gruppe (WM8-125).
            if selectedGroupID != nil, selectedKey != nil { selectedGroupID = nil }
        }
    }
    /// Controller und Pfeiltasten (WM8-125): Die Auswahl steht auf dem Kopf
    /// dieser Gruppe der Liste; Return oder Kreuz klappt sie auf und zu.
    var selectedGroupID: String? {
        didSet { if selectedGroupID != nil, selectedKey != nil { selectedKey = nil } }
    }
    /// Controller (WM8-91): Die Auswahl steht auf „N weitere“ dieser Spalte.
    var moreColumn: String?
    /// Controller (WM8-91): Fokus in der Triage, Liste oder Chat-Zeile.
    var triageFocus: TicketTriageFocus = .list

    private(set) var presentation: TicketBoardPresentation = .empty
    /// Eckdaten des gewählten Tickets (Eigenschaften, Chats, Adresse).
    /// Gerechnet beim Wählen und bei einem neuen Abzug, nicht beim Zeichnen.
    private(set) var detail: TicketDetailContent?
    /// Offene Triage; `nil` zeigt das Board oder die Liste.
    private(set) var triage: TicketTriage? {
        didSet {
            // Triage auf oder zu: Der Kopf hat dann andere Knöpfe; die Auswahl
            // dort beginnt neu, und die Leiste des Controllers liest neu.
            guard (triage == nil) != (oldValue == nil) else { return }
            headerFocus = nil
            morePickerIndex = nil
            columnFocus = nil
            columnPickerIndex = nil
            onControllerViewChange?()
        }
    }
    /// Kommentare des Tickets in der Triage.
    private(set) var comments: TicketCommentsLoad = .loading
    /// Fertiger Text für die Mitte der Triage.
    private(set) var document: TicketDocument?
    /// Zuletzt kopiert; die Knöpfe zeigen kurz „Kopiert“.
    private(set) var copied: TicketCopyFeedback?

    var selected: TicketBoardEntry? { detail?.entry }
    @ObservationIgnored private var model = TicketBoardModel(entries: [], looseChats: [], supervisors: [])
    /// Wie oft der Inhalt neu gerechnet wurde (für Tests).
    @ObservationIgnored private(set) var rebuilds = 0
    /// Ein anderes Ticket steht in der Triage (oder `nil`: Triage zu). Der
    /// Controller holt dann die Kommentare.
    @ObservationIgnored var onShowTicket: ((Ticket?) -> Void)?
    /// „Aktualisieren“ in der Triage: Kommentare des gezeigten Tickets neu holen.
    @ObservationIgnored var onReloadComments: ((Ticket) -> Void)?
    /// Schreibt in die Zwischenablage; Tests ersetzen das.
    @ObservationIgnored var copyToClipboard: (String) -> Void = { TicketClipboard.copy($0) }
    @ObservationIgnored private var copiedReset: Task<Void, Never>?
    @ObservationIgnored private let documentBuilding: TicketDocumentBuilding
    @ObservationIgnored private var documentInput: TicketTextDocument.Input?
    @ObservationIgnored private var documentTask: Task<Void, Never>?
    @ObservationIgnored private var documentRevision = 0
    /// Ticket, für das zuletzt `onShowTicket` lief (ID und Stand).
    @ObservationIgnored private var shownTicket: (id: String, updatedAt: Date?)?

    init(model: TicketBoardModel? = nil, documents: TicketDocumentBuilding = .background) {
        documentBuilding = documents
        if let model { update(model) }
    }

    /// Neuer Abzug oder geänderte Chats. Der Zustand der Chats zählt hier nicht:
    /// Den führt die `TicketChatStatusSource`, damit ein Statuswechsel nichts
    /// neu rechnet.
    func update(_ fresh: TicketBoardModel) {
        let model = fresh.withoutChatStates
        guard model != self.model else { return }
        self.model = model
        rebuild()
        // Ein Ticket, das der Filter ausblendet, bleibt gewählt; eines, das es nicht mehr gibt, nicht.
        if let key = selectedKey, !model.entries.contains(where: { $0.ticket.key == key }) { selectedKey = nil }
    }

    /// Anderes Projekt oder Team: Filter und Auswahl gehören zum alten.
    func reset() {
        setTriage(nil)
        selectedKey = nil
        mode = .list
        catalog = .empty
        activeViewID = nil
        isViewLoading = false
        collapsedGroups = []
        model = TicketBoardModel(entries: [], looseChats: [], supervisors: [])
        rebuild()
    }

    private func rebuild() {
        rebuilds += 1
        // Gefiltert wird bei Linear über die Ansicht (WM8-125); das Board filtert nicht mehr selbst.
        let fresh = TicketBoardPresentation.make(model: model, filter: .all)
        if fresh != presentation { presentation = fresh }
        if let triage {
            // Neuer Abzug: Liste aus derselben Quelle, das Ticket bleibt, wenn es kann.
            let reconciled = TicketBoardSelection.reconcile(triage, fresh: keys(for: triage.source))
            if reconciled != triage { setTriage(reconciled) }
        }
        refreshSelection()
        refreshTriageTicket()
    }

    /// Setzt die Triage; Auswahl, Kommentare und Text folgen.
    func setTriage(_ fresh: TicketTriage?) {
        guard fresh != triage else { return }
        // Anderes Ticket oder Triage zu: Der Fokus geht zurück in die Liste.
        if fresh?.current != triage?.current, triageFocus != .list { triageFocus = .list }
        triage = fresh
        if let fresh { selectedKey = fresh.current }
        refreshTriageTicket()
    }

    func noteCopied(_ kind: TicketCopyFeedback) {
        copied = kind
        copiedReset?.cancel()
        copiedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.copied = nil
        }
    }

    /// Kommentare für ein Ticket; zählen nur, solange es noch gezeigt wird.
    func setComments(_ load: TicketCommentsLoad, ticketID: String) {
        guard shownTicket?.id == ticketID, load != comments else { return }
        comments = load
        rebuildDocument()
    }

    func reloadComments() {
        guard let ticket = detail?.entry.ticket, triage != nil else { return }
        onReloadComments?(ticket)
    }

    /// Steht ein anderes Ticket (oder ein neuer Stand davon) in der Triage,
    /// werden Kommentare angefordert und der Text neu gebaut.
    private func refreshTriageTicket() {
        guard triage != nil, let ticket = detail?.entry.ticket, ticket.key == triage?.current else {
            if triage == nil, shownTicket != nil {
                shownTicket = nil
                documentTask?.cancel()
                document = nil
                documentInput = nil
                onShowTicket?(nil)
            }
            return
        }
        if shownTicket?.id != ticket.id || shownTicket?.updatedAt != ticket.updatedAt {
            let isOther = shownTicket?.id != ticket.id
            shownTicket = (ticket.id, ticket.updatedAt)
            // Ein anderes Ticket lädt; ein neuer Stand desselben behält, was er hat, bis Neues kommt.
            if isOther, comments != .loading { comments = .loading }
            onShowTicket?(ticket)
        }
        rebuildDocument()
    }

    private func rebuildDocument() {
        guard let ticket = detail?.entry.ticket, triage != nil else { return }
        let input = TicketTextDocument.Input(title: ticket.title, description: ticket.description, comments: comments)
        guard input != documentInput else { return }
        documentInput = input
        documentRevision += 1
        let revision = documentRevision, key = ticket.key
        documentTask?.cancel()
        if document?.ticketKey != key, documentBuilding == .background {
            // Anderes Ticket: sofort ein kleines Dokument mit dem Titel, synchron
            // und billig. So springt der Titel mit der Nummer, die Mitte bleibt
            // nie leer, und die Textansicht wird nicht neu aufgebaut. Der volle
            // Text ersetzt es, sobald er fertig ist (eigene, höhere Revision).
            document = TicketDocument(ticketKey: key, revision: revision, text: TicketTextDocument.placeholder(title: ticket.title))
            documentRevision += 1
        }
        let fullRevision = documentRevision
        switch documentBuilding {
        case .immediate:
            document = TicketDocument(ticketKey: key, revision: revision, text: TicketTextDocument.make(input))
        case .background:
            documentTask = Task { [weak self] in
                let built = await Task.detached(priority: .userInitiated) { () -> TicketBuiltText in
                    TicketBuiltText(text: PerfBudgets.ticketsDocument.withInterval { TicketTextDocument.make(input) })
                }.value
                let text = built.text
                guard let self, !Task.isCancelled, fullRevision == self.documentRevision else { return }
                self.document = TicketDocument(ticketKey: key, revision: fullRevision, text: text)
            }
        }
    }

    private func refreshSelection() {
        guard let entry = presentation.entry(key: selectedKey) else {
            if detail != nil { detail = nil }
            return
        }
        guard entry != detail?.entry else { return }
        detail = TicketDetailContent.make(entry)
    }
}

/// Was zuletzt kopiert wurde, für die kurze Rückmeldung am Knopf.
enum TicketCopyFeedback: Equatable {
    case link
    case list
}

/// Fertiger Text aus dem Hintergrund. Nach dem Bau wird er nicht mehr
/// verändert, nur im Main Thread gesetzt.
struct TicketBuiltText: @unchecked Sendable {
    let text: NSAttributedString
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
    var agents: [AgentLine]
    /// Der erste Chat, der auf diesem Rechner läuft.
    var localChatID: UUID?
    /// Adresse im Ticket-Werkzeug; nur `https`.
    var url: URL?

    static func make(_ entry: TicketBoardEntry) -> TicketDetailContent {
        let url = entry.ticket.url.flatMap(URL.init(string:)).flatMap { $0.scheme?.lowercased() == "https" && $0.host != nil ? $0 : nil }
        return TicketDetailContent(
            entry: entry,
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
