import Foundation
import Observation

// MARK: - Übersicht der geplanten Aufgaben für die Ansicht (WM8-110, Paket 2)

/// Hält, was Seitenleiste und Detail zeigen. Geladen wird abseits des Main
/// Threads und nur auf Anlass: erstes Erscheinen, nach jedem Durchlauf des
/// Planers (Termin, Aufwachen, CLI-Änderung), am Ende eines Laufs und nach einer
/// Aktion aus der Ansicht. Kein Polling, kein Datei-Beobachter.
///
/// Ändert sich nichts, bleibt `snapshot` unangetastet: Beobachter rechnen dann
/// nicht neu.
@MainActor
@Observable
final class ScheduledTasksOverviewModel {
    static let shared = ScheduledTasksOverviewModel()

    struct Dependencies {
        var load: @Sendable () -> ScheduledTaskOverviewLoader.Snapshot
        /// Planer der laufenden App; `nil` = Schalter aus.
        var scheduler: @MainActor () -> ScheduledTaskScheduler?
        /// Nach einer Änderung: Zeitgeber neu stellen.
        var afterChange: @MainActor () -> Void

        static var live: Dependencies {
            Dependencies(
                load: {
                    ScheduledTaskOverviewLoader.load(
                        store: ScheduledTaskStore(), now: Date(), calendar: .current,
                        isProcessAlive: { ScheduledTaskRunEvaluator.isProcessAlive(pid: $0, startedAt: $1) })
                },
                scheduler: {
                    guard AppPreferences.shared.isScheduledTasksEnabled else { return nil }
                    let runtime = ScheduledTaskRuntime.shared
                    if !runtime.isRunning { runtime.start() }
                    return runtime.scheduler
                },
                afterChange: { ScheduledTaskRuntime.shared.tick(reason: "ui") }
            )
        }
    }

    private(set) var snapshot = ScheduledTaskOverviewLoader.Snapshot()
    /// Stand der Uhr beim letzten Laden; Zeiten in der Ansicht rechnen damit.
    private(set) var loadedAt = Date()
    /// Wurde schon einmal geladen? Vorher zeigt die Ansicht nichts statt „keine Aufgaben“.
    private(set) var hasLoaded = false

    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var reloadPending = false

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    func overview(id: UUID) -> ScheduledTaskOverview? {
        snapshot.overviews.first { $0.id == id }
    }

    /// Erstes Erscheinen einer Ansicht.
    func loadIfNeeded() {
        guard !hasLoaded else { return }
        reload()
    }

    /// Neu laden. Läuft schon ein Laden, folgt genau eines danach.
    func reload() {
        guard !isLoading else {
            reloadPending = true
            return
        }
        isLoading = true
        let load = dependencies.load
        Task.detached(priority: .utility) {
            let result = load()
            await MainActor.run { [weak self] in self?.apply(result) }
        }
    }

    /// Für Tests und Snapshots: ohne Laden setzen.
    func apply(_ result: ScheduledTaskOverviewLoader.Snapshot, at date: Date = Date()) {
        isLoading = false
        loadedAt = date
        if !hasLoaded { hasLoaded = true }
        if snapshot != result { snapshot = result }
        if reloadPending {
            reloadPending = false
            reload()
        }
    }

    // MARK: Aktionen (gleicher Weg wie `whisperm8 schedule …`)

    /// Fehlertext oder `nil`.
    func runNow(_ id: UUID) async -> String? {
        await perform { scheduler in
            let record = try await scheduler.runNow(id: id)
            guard record.notStarted != nil else { return nil }
            // Vorab-Prüfung hat den Start verhindert; der Eintrag steht in den Läufen.
            return record.notStarted.map { ScheduledTaskTexts.outcomeTitle(.notStarted($0, message: record.message)) }
        }
    }

    func setPaused(_ id: UUID, paused: Bool) async -> String? {
        await perform { scheduler in
            _ = try await scheduler.setPaused(id: id, paused: paused)
            return nil
        }
    }

    func remove(_ id: UUID) async -> String? {
        await perform { scheduler in
            _ = try await scheduler.remove(id: id)
            return nil
        }
    }

    /// Anlegen (`id == nil`) oder Ändern. Gibt bei Erfolg die Aufgabe zurück.
    func save(_ draft: ScheduledTaskDraft, id: UUID?) async -> Result<ScheduledTask, ScheduledTaskSaveError> {
        guard let scheduler = dependencies.scheduler() else {
            return .failure(ScheduledTaskSaveError(message: ScheduledTaskScheduler.SchedulerError.disabled.localizedDescription))
        }
        do {
            let task: ScheduledTask
            if let id {
                task = try await scheduler.edit(id: id, draft: draft)
            } else {
                task = try await scheduler.add(draft)
            }
            insertOrReplace(task)
            afterChange()
            return .success(task)
        } catch {
            return .failure(ScheduledTaskSaveError(message: error.localizedDescription))
        }
    }

    /// Neue oder geänderte Aufgabe sofort zeigen, bis das Laden nachzieht:
    /// Sonst stünde nach dem Anlegen kurz „gibt es nicht mehr“ im Detail.
    func insertOrReplace(_ task: ScheduledTask, now: Date = Date(), calendar: Calendar = .current) {
        var overviews = snapshot.overviews
        let runs = overviews.first { $0.id == task.id }?.runs ?? []
        let next = task.paused ? nil : ScheduledTaskCalendar.nextOccurrence(of: task.schedule, after: now, calendar: calendar)
        let overview = ScheduledTaskOverview(task: task, next: next, runs: runs,
                                             state: ScheduledTaskOverview.state(paused: task.paused, runs: runs))
        if let index = overviews.firstIndex(where: { $0.id == task.id }) {
            overviews[index] = overview
        } else {
            overviews.append(overview)
        }
        snapshot.overviews = overviews
        hasLoaded = true
    }

    private func perform(_ body: (ScheduledTaskScheduler) async throws -> String?) async -> String? {
        guard let scheduler = dependencies.scheduler() else {
            return ScheduledTaskScheduler.SchedulerError.disabled.localizedDescription
        }
        let message: String?
        do {
            message = try await body(scheduler)
        } catch {
            message = error.localizedDescription
        }
        afterChange()
        return message
    }

    private func afterChange() {
        dependencies.afterChange()
        reload()
    }
}

struct ScheduledTaskSaveError: Error, Equatable {
    var message: String
}
