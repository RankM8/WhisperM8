import Foundation

// MARK: - Übersicht für die Ansicht „Geplant“ (WM8-110, Paket 2)

/// Ein Lauf, wie ihn Seitenleiste und Detail zeigen. Abgeleitet aus dem
/// Lauf-Ordner beim Laden, nie im Renderpfad.
struct ScheduledTaskRunSummary: Equatable, Identifiable {
    var id: String
    var createdAt: Date
    var trigger: ScheduledTaskRunRecord.Trigger
    /// Sitzung des Laufs (`--session-id`); `nil` = nicht gestartet, kein Chat.
    var sessionID: UUID?
    var outcome: ScheduledTaskRunOutcome
    /// Laufzeit in Sekunden, sobald der Lauf fertig ist.
    var durationSeconds: Int?

    init(files: ScheduledTaskRunFiles, outcome: ScheduledTaskRunOutcome) {
        let record = files.record
        id = record.runID
        createdAt = record.createdAt
        trigger = record.trigger
        sessionID = record.sessionID
        self.outcome = outcome
        if let ended = files.exit?.endedAt {
            let seconds = Int(ended.timeIntervalSince(record.processStartedAt ?? record.createdAt))
            durationSeconds = seconds >= 0 ? seconds : nil
        }
    }

    init(id: String, createdAt: Date, trigger: ScheduledTaskRunRecord.Trigger = .schedule, sessionID: UUID?,
         outcome: ScheduledTaskRunOutcome, durationSeconds: Int? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.trigger = trigger
        self.sessionID = sessionID
        self.outcome = outcome
        self.durationSeconds = durationSeconds
    }

    /// Hat der Lauf einen Chat, den man öffnen kann?
    var hasChat: Bool { sessionID != nil }
}

/// Eine Aufgabe mit nächstem Termin und letzten Läufen.
struct ScheduledTaskOverview: Equatable, Identifiable {
    enum State: Equatable {
        /// Noch kein Lauf oder nur verpasste/übersprungene Termine.
        case scheduled
        case running
        case succeeded
        case succeededWithNotes
        case failed
        case paused
    }

    var task: ScheduledTask
    var next: Date?
    /// Neueste zuerst.
    var runs: [ScheduledTaskRunSummary]
    var state: State
    /// Lauf-Ordner im Archiv (Paket 3).
    var archivedCount = 0

    var id: UUID { task.id }

    /// Laufender Lauf, falls einer arbeitet.
    var activeRun: ScheduledTaskRunSummary? { runs.first { $0.outcome.isActive } }

    /// Jüngster Lauf, der ein Ergebnis hat (verpasst und übersprungen zählen nicht).
    var latestResult: ScheduledTaskRunSummary? {
        runs.first { run in
            if case .notStarted(let reason, _) = run.outcome { return reason != .missed && reason != .stillRunning }
            return true
        }
    }

    static func state(paused: Bool, runs: [ScheduledTaskRunSummary]) -> State {
        if runs.contains(where: { $0.outcome.isActive }) { return .running }
        if paused { return .paused }
        let latest = runs.first { run in
            if case .notStarted(let reason, _) = run.outcome { return reason != .missed && reason != .stillRunning }
            return true
        }
        guard let latest else { return .scheduled }
        switch latest.outcome {
        case .succeeded: return .succeeded
        case .succeededWithNotes: return .succeededWithNotes
        case .starting, .running: return .running
        case .failed, .aborted, .notStarted: return .failed
        }
    }
}

enum ScheduledTaskOverviewLoader {
    /// Läufe je Aufgabe, die die Ansicht liest. Die Seitenleiste zeigt drei,
    /// das Detail alle geladenen. Ältere stehen mit `whisperm8 schedule show`.
    static let runLimit = 20

    struct Snapshot: Equatable {
        var overviews: [ScheduledTaskOverview] = []
        /// Klartext, wenn `scheduled-tasks.json` nicht lesbar ist.
        var loadError: String?
    }

    /// Liest Aufgaben und Lauf-Ordner. Blockierendes I/O: nur abseits des Main
    /// Threads aufrufen (`ScheduledTasksOverviewModel`).
    static func load(store: ScheduledTaskStore, now: Date, calendar: Calendar, runLimit: Int = runLimit,
                     isProcessAlive: (Int32, Date?) -> Bool) -> Snapshot {
        let file: ScheduledTasksFile
        do {
            file = try store.load()
        } catch {
            return Snapshot(loadError: ScheduledTaskTexts.error(error))
        }
        let overviews = file.tasks.map { task -> ScheduledTaskOverview in
            var runs = store.recentRuns(for: task.id, limit: runLimit).map { files in
                ScheduledTaskRunSummary(files: files, outcome: ScheduledTaskRunEvaluator.outcome(
                    of: files, now: now, isProcessAlive: isProcessAlive))
            }
            // Arbeitet ein älterer Lauf hinter vielen übersprungenen Terminen,
            // steht er nicht unter den geladenen; dann gehört er nach vorn.
            if !runs.contains(where: { $0.outcome.isActive }),
               let started = store.latestStartedRun(for: task.id),
               !runs.contains(where: { $0.id == started.record.runID }) {
                let outcome = ScheduledTaskRunEvaluator.outcome(of: started, now: now, isProcessAlive: isProcessAlive)
                if outcome.isActive { runs.insert(ScheduledTaskRunSummary(files: started, outcome: outcome), at: 0) }
            }
            let next = task.paused ? nil
                : ScheduledTaskCalendar.nextOccurrence(of: task.schedule, after: now, calendar: calendar)
            return ScheduledTaskOverview(task: task, next: next, runs: runs,
                                         state: ScheduledTaskOverview.state(paused: task.paused, runs: runs),
                                         archivedCount: store.archivedRunCount(for: task.id))
        }
        return Snapshot(overviews: overviews)
    }
}

/// Endet der Login des Kontos vor dem nächsten Termin? Dann startet der Lauf
/// nicht (der Planer prüft `claude auth status`) und meldet sich als
/// fehlgeschlagen. Rein, getestet; das Enddatum kommt aus
/// `ClaudeLoginExpiryStore` (dieselbe Quelle wie die Ablaufanzeige der Konten).
struct ScheduledTaskLoginWarning: Equatable {
    var endsAt: Date
    var next: Date
    var hasEnded: Bool

    static func check(loginEndsAt: Date?, next: Date?, now: Date) -> ScheduledTaskLoginWarning? {
        // Pausiert oder ohne Termin: Es startet nichts, das scheitern könnte.
        guard let loginEndsAt, let next, loginEndsAt <= next else { return nil }
        return ScheduledTaskLoginWarning(endsAt: loginEndsAt, next: next, hasEnded: loginEndsAt <= now)
    }
}
