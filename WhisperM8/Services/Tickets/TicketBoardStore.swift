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

    @ObservationIgnored private let source: TicketSource
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private var loop: Task<Void, Never>?

    init(
        source: TicketSource,
        interval: Duration = .seconds(30),
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.source = source
        self.interval = interval
        self.sleep = sleep
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
        self.team = team
        // Takt und Wartefunktion vorab kopieren: Während des Wartens soll die
        // Schleife den Speicher nicht am Leben halten.
        let interval = interval
        let sleep = sleep
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
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

    /// Ein Abruf sofort. Läuft schon einer, wird kein zweiter gestartet.
    func refresh() async {
        guard let team, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await source.board(team: team)
            // Zwischendurch das Team gewechselt: Antwort gehört nicht mehr hierher.
            guard self.team == team else { return }
            snapshot = fresh
            lastError = nil
        } catch let error as TicketSourceError {
            guard self.team == team else { return }
            lastError = error
        } catch {
            guard self.team == team else { return }
            lastError = .network("Netzfehler")
        }
    }

    var isActive: Bool { loop != nil }
}
