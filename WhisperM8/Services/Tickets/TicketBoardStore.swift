import Foundation
import Observation

// MARK: - Abzug des Boards mit Takt

/// Hält den letzten Abzug eines Teams und fragt im Takt nach, aber nur,
/// solange jemand ihn braucht (`activate`/`deactivate`). Ansichten lesen nur;
/// Netz und Übersetzung laufen in der Quelle, abseits des Main Threads.
///
/// Ein Fehler lässt den letzten Abzug stehen: Das Board zeigt dann den alten
/// Stand samt Alter, statt leer zu werden.
@MainActor
@Observable
final class TicketBoardStore {
    private(set) var snapshot: TicketBoardSnapshot?
    /// Fehler des letzten Abrufs; `nil` nach einem gelungenen.
    private(set) var lastError: TicketSourceError?
    private(set) var isLoading = false
    private(set) var team: String?
    /// Reiter des Workspaces (WM8-125); `nil`, solange nicht geladen.
    private(set) var catalog: TicketViewCatalog?
    /// Tickets je Ansicht, zuletzt geholt. Nur die gezeigte wird im Takt geholt.
    private(set) var viewTickets: [String: TicketViewTickets] = [:]
    /// Fehler beim Holen der Ansichten; das Board der Team-Tickets bleibt davon unberührt.
    private(set) var viewError: TicketSourceError?
    /// Gezeigte Ansicht; `nil` = Standard des Katalogs.
    var viewID: String? {
        didSet {
            guard viewID != oldValue, loop != nil, let id = effectiveViewID, !isFresh(id) else { return }
            Task { [weak self] in await self?.refreshView(id) }
        }
    }

    /// Takt, solange die Ansicht sichtbar ist. Jeder Abruf kostet mindestens
    /// zwei Anfragen aus dem Stundenbudget des Keys (2.500), und derselbe Key
    /// trägt jeden `tickets`-Befehl aller Chats. Startwert nach der Messung
    /// vom 14.11.2026 (2 Anfragen, 140 Punkte je Abruf); siehe Feature-Doku.
    static let defaultInterval: Duration = .seconds(120)
    /// So lange ruht der Takt, nachdem Linear „Rate limited“ gemeldet hat.
    static let rateLimitPause: TimeInterval = 15 * 60
    /// So lange gelten die Reiter. Sie ändern sich selten; der Knopf holt sie sofort.
    static let catalogLifetime: TimeInterval = 10 * 60

    @ObservationIgnored private let source: TicketSource
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private let now: () -> Date
    /// Bis dahin fragt der Takt nicht: Das Budget des Keys ist erschöpft, und
    /// weiterzufragen nähme es auch den Chats. Der Knopf fragt trotzdem.
    @ObservationIgnored private(set) var pausedUntil: Date?
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// Für welches Team gerade ein Abruf läuft. Je Team, nicht ein Schalter:
    /// Nach einem Teamwechsel darf das neue Team sofort laden.
    @ObservationIgnored private var loadingTeam: String?
    /// Jemand wollte abrufen, während ein Abruf lief. Endet der mit einem
    /// Abbruch (Ansicht kurz verdeckt), wird sofort nachgeholt; sonst stünde
    /// die wieder gezeigte Ansicht bis zum nächsten Takt ohne Stand da.
    @ObservationIgnored private var refreshWanted = false
    @ObservationIgnored private var catalogFetchedAt: Date?
    /// Ansichten, für die gerade ein Abruf läuft.
    @ObservationIgnored private var loadingViews = Set<String>()
    /// Beginn und Ende jedes Abrufs. Die Ansicht gleicht hier ab, statt den
    /// Speicher in ihrer Wurzel zu beobachten: So zeichnet ein Abruf nur die
    /// Zeile im Kopf neu.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    init(
        source: TicketSource,
        interval: Duration = TicketBoardStore.defaultInterval,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.source = source
        self.interval = interval
        self.sleep = sleep
        self.now = now
    }

    /// Die Ansicht ist sichtbar: sofort laden, danach im Takt. Derselbe Aufruf
    /// für dasselbe Team ändert nichts; ein anderes Team verwirft den Abzug.
    func activate(team: String) {
        if self.team == team, loop != nil { return }
        loop?.cancel()
        loop = nil
        if self.team != team {
            snapshot = nil
            lastError = nil
            // Die Reiter gehören dem Workspace, die gezeigte Ansicht dem Board.
            viewID = nil
        }
        // `pausedUntil` bleibt: Das Budget gehört dem Key, nicht dem Team.
        self.team = team
        // Takt und Wartefunktion vorab kopieren: Während des Wartens soll die
        // Schleife den Speicher nicht am Leben halten.
        let interval = interval
        let sleep = sleep
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(byTimer: true)
                if self == nil { return }
                do { try await sleep(interval) } catch { return }
            }
        }
    }

    /// Die Ansicht ist verdeckt oder geschlossen: kein Abruf mehr. Der Abzug
    /// bleibt für das nächste Öffnen stehen.
    func deactivate() {
        loop?.cancel()
        loop = nil
    }

    /// Ein Abruf sofort. Läuft für dieses Team schon einer, wird kein zweiter gestartet.
    /// `byTimer`: Der Takt (und das Sichtbarwerden) fragt; während der Pause
    /// nach „Rate limited“ entfällt das. Der Knopf im Kopf fragt immer.
    func refresh(byTimer: Bool = false) async {
        guard let team else { return }
        if byTimer, let pausedUntil, now() < pausedUntil { return }
        guard loadingTeam != team else {
            refreshWanted = true
            return
        }
        loadingTeam = team
        refreshWanted = false
        isLoading = true
        onChange?()
        var wasCancelled = false
        defer {
            // Hat inzwischen ein anderes Team übernommen, gehört der Schalter ihm.
            if loadingTeam == team {
                loadingTeam = nil
                isLoading = false
            }
            onChange?()
            if wasCancelled, refreshWanted, self.team == team, loop != nil {
                // Eigene Task: Diese hier ist abgebrochen.
                Task { [weak self] in await self?.refresh(byTimer: true) }
            }
        }
        do {
            let source = source
            let fresh = try await PerfBudgets.ticketsFetch.withInterval { try await source.board(team: team) }
            // Zwischendurch das Team gewechselt: Antwort gehört nicht mehr hierher.
            guard self.team == team else { return }
            snapshot = fresh
            lastError = nil
            pausedUntil = nil
            // Reiter und Ansicht nach dem Board: Ein Fehler dort lässt das Board stehen.
            await refreshCatalog(force: !byTimer)
            if let id = effectiveViewID { await refreshView(id) }
        } catch is CancellationError {
            // Ansicht geschlossen: kein Fehler, der letzte Stand bleibt.
            wasCancelled = true
        } catch let error as TicketSourceError {
            if error == .rateLimited { pausedUntil = now().addingTimeInterval(Self.rateLimitPause) }
            guard self.team == team else { return }
            lastError = error
        } catch {
            guard self.team == team else { return }
            lastError = .network("Netzfehler")
        }
    }

    var isActive: Bool { loop != nil }

    // MARK: Ansichten (WM8-125)

    /// Gewählte Ansicht, sonst der Standard des Katalogs.
    var effectiveViewID: String? {
        guard let catalog else { return nil }
        if let viewID, catalog.views.contains(where: { $0.id == viewID }) { return viewID }
        return catalog.defaultID
    }

    private func isFresh(_ viewID: String) -> Bool {
        guard let hit = viewTickets[viewID] else { return false }
        return now().timeIntervalSince(hit.fetchedAt) < TimeInterval(interval.components.seconds)
    }

    /// Eine Anfrage, höchstens alle zehn Minuten (der Knopf: sofort).
    private func refreshCatalog(force: Bool) async {
        if !force, catalog != nil, let catalogFetchedAt, now().timeIntervalSince(catalogFetchedAt) < Self.catalogLifetime { return }
        let team = team
        let source = source
        do {
            let fresh = try await PerfBudgets.ticketsFetch.withInterval { try await source.views() }
            guard self.team == team else { return }
            catalog = fresh
            catalogFetchedAt = now()
            viewError = nil
        } catch is CancellationError {
            return
        } catch let error as TicketSourceError {
            if error == .rateLimited { pausedUntil = now().addingTimeInterval(Self.rateLimitPause) }
            viewError = error
        } catch {
            viewError = .network("Netzfehler")
        }
        onChange?()
    }

    /// Tickets einer Ansicht. Während der Pause nach „Rate limited“ nicht.
    func refreshView(_ viewID: String) async {
        guard !loadingViews.contains(viewID) else { return }
        if let pausedUntil, now() < pausedUntil { return }
        loadingViews.insert(viewID)
        defer { loadingViews.remove(viewID) }
        let source = source
        do {
            let tickets = try await PerfBudgets.ticketsFetch.withInterval { try await source.tickets(inView: viewID) }
            viewTickets[viewID] = TicketViewTickets(tickets: tickets, fetchedAt: now())
            viewError = nil
        } catch is CancellationError {
            return
        } catch let error as TicketSourceError {
            if error == .rateLimited { pausedUntil = now().addingTimeInterval(Self.rateLimitPause) }
            viewError = error
        } catch {
            viewError = .network("Netzfehler")
        }
        onChange?()
    }

    // MARK: Kommentare

    /// Kommentare je Ticket für diese Sitzung der App. Ein Eintrag gilt,
    /// solange sich das Ticket nicht geändert hat (`updatedAt`) und höchstens
    /// `commentLifetime` lang: Ob Linear `updatedAt` bei einem neuen Kommentar
    /// setzt, ist nicht geprüft, und Chats schreiben Zwischenstände als
    /// Kommentar. „Aktualisieren“ in der Triage verwirft ihn sofort. Je
    /// Workspace ein Speicher, also auch ein Cache.
    @ObservationIgnored private var commentCache: [String: (updatedAt: Date?, fetchedAt: Date, comments: TicketComments)] = [:]
    static let commentLifetime: TimeInterval = 120

    /// Schon geholt und noch gültig?
    func cachedComments(for ticket: Ticket) -> TicketComments? {
        guard let hit = commentCache[ticket.id], hit.updatedAt == ticket.updatedAt,
              now().timeIntervalSince(hit.fetchedAt) < Self.commentLifetime else { return nil }
        return hit.comments
    }

    func forgetComments(ticketID: String) {
        commentCache[ticketID] = nil
    }

    /// Eine Anfrage, außer der Zwischenspeicher hat das Ticket schon. Während
    /// der Pause nach „Rate limited“ wird nicht gefragt: Das Budget gehört auch
    /// den Chats.
    func comments(for ticket: Ticket) async throws -> TicketComments {
        if let cached = cachedComments(for: ticket) { return cached }
        if let pausedUntil, now() < pausedUntil { throw TicketSourceError.rateLimited }
        let source = source
        do {
            let fresh = try await PerfBudgets.ticketsComments.withInterval { try await source.comments(ticketID: ticket.id) }
            commentCache[ticket.id] = (ticket.updatedAt, now(), fresh)
            return fresh
        } catch let error as TicketSourceError {
            if error == .rateLimited { pausedUntil = now().addingTimeInterval(Self.rateLimitPause) }
            throw error
        }
    }
}

/// Tickets einer Ansicht mit dem Zeitpunkt des Abrufs.
struct TicketViewTickets: Equatable {
    var tickets: [Ticket]
    var fetchedAt: Date
}
