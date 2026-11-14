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

    /// Takt, solange die Ansicht sichtbar ist. Jeder Abruf kostet mindestens
    /// zwei Anfragen aus dem Stundenbudget des Keys (2.500), und derselbe Key
    /// trägt jeden `tickets`-Befehl aller Chats. Startwert nach der Messung
    /// vom 14.11.2026 (2 Anfragen, 140 Punkte je Abruf); siehe Feature-Doku.
    static let defaultInterval: Duration = .seconds(120)
    /// So lange ruht der Takt, nachdem Linear „Rate limited“ gemeldet hat.
    static let rateLimitPause: TimeInterval = 15 * 60

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
        if self.team != team {
            snapshot = nil
            lastError = nil
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
}
