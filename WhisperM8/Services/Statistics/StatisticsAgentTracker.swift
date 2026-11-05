import Foundation

/// Integriert, wie viele Chats gleichzeitig arbeiten. Rein und ohne Uhr: Jede
/// Änderung der Anzahl schließt einen Abschnitt `[start, end)` mit konstanter
/// Anzahl ab. Die Abschnitte sammeln sich im Speicher, bis `drain` sie abholt.
struct StatisticsConcurrencyIntegrator: Equatable {
    struct Segment: Equatable, Sendable {
        var start: Date
        var end: Date
        var count: Int
    }

    private(set) var working: Set<UUID> = []
    /// Beginn des offenen Abschnitts; `nil`, solange niemand arbeitet oder die
    /// Messung pausiert (Ruhezustand).
    private var openSince: Date?
    private(set) var isSuspended = false
    private(set) var pending: [Segment] = []

    var count: Int { working.count }

    /// Setzt den Arbeitsstand einer Session. `true`, wenn sich die Anzahl
    /// geändert hat.
    @discardableResult
    mutating func set(_ sessionID: UUID, working isWorking: Bool, at now: Date) -> Bool {
        let before = working.count
        if isWorking {
            working.insert(sessionID)
        } else {
            working.remove(sessionID)
        }
        guard working.count != before else { return false }
        close(at: now, count: before)
        openSince = working.isEmpty || isSuspended ? nil : now
        return true
    }

    /// Gibt alle fertigen Abschnitte heraus. Ein offener Abschnitt wird bei
    /// `now` geteilt und läuft danach weiter.
    mutating func drain(at now: Date) -> [Segment] {
        if openSince != nil {
            close(at: now, count: working.count)
            openSince = now
        }
        let result = pending
        pending = []
        return result
    }

    /// Ruhezustand: bis `now` buchen, danach zählt nichts, bis `resume` kommt.
    mutating func suspend(at now: Date) {
        close(at: now, count: working.count)
        openSince = nil
        isSuspended = true
    }

    mutating func resume(at now: Date) {
        guard isSuspended else { return }
        isSuspended = false
        openSince = working.isEmpty ? nil : now
    }

    /// Alles abschließen und vergessen (Statistik aus).
    mutating func reset(at now: Date) -> [Segment] {
        let result = drain(at: now)
        working = []
        openSince = nil
        isSuspended = false
        return result
    }

    private mutating func close(at now: Date, count: Int) {
        guard count > 0, let start = openSince, now > start else { return }
        pending.append(Segment(start: start, end: now, count: count))
    }

    /// Verteilt Abschnitte auf Tage und Stunden. Läuft auf der Store-Queue.
    static func apply(_ segments: [Segment], to db: inout StatsDatabase, calendar: Calendar) {
        for segment in segments where segment.count > 0 {
            for slice in StatisticsTime.slices(from: segment.start, to: segment.end, calendar: calendar) {
                db.updateDay(slice.dayKey) { day in
                    day.agentWorkingSeconds += slice.seconds
                    day.concurrencySeconds += slice.seconds * Double(segment.count)
                    day.addHourly(agent: slice.seconds, hour: slice.hour)
                    day.peakConcurrent = max(day.peakConcurrent, segment.count)
                }
            }
        }
    }
}

/// Zählt Agenten-Zeit und gleichzeitig arbeitende Chats. Der Status-Koordinator
/// meldet jede Änderung; hier wird nur ein Set angepasst (O(1)). In den Store
/// geschrieben wird gebündelt: einmal pro Minute, solange jemand arbeitet, und
/// sofort, wenn der letzte Chat aufhört. Ohne arbeitende Chats läuft kein Timer.
@MainActor
final class StatisticsAgentTracker {
    struct Environment {
        var now: () -> Date
        var calendar: Calendar
        /// `nil`: kein Timer (Tests rufen `flush()` selbst).
        var flushInterval: TimeInterval?

        static var live: Environment {
            Environment(now: Date.init, calendar: .current, flushInterval: 60)
        }
    }

    private let store: StatisticsStore
    private let env: Environment
    private var integrator = StatisticsConcurrencyIntegrator()
    private var timer: Timer?
    private var running = false

    init(store: StatisticsStore, environment: Environment) {
        self.store = store
        self.env = environment
    }

    var workingCount: Int { integrator.count }

    /// - Parameter workingSessionIDs: Chats, die beim Einschalten schon arbeiten.
    func start(workingSessionIDs: Set<UUID> = []) {
        guard !running else { return }
        running = true
        let now = env.now()
        for id in workingSessionIDs {
            integrator.set(id, working: true, at: now)
        }
        updateTimer()
    }

    func stop() {
        guard running else { return }
        running = false
        write(integrator.reset(at: env.now()))
        updateTimer()
    }

    func setWorking(_ sessionID: UUID, working: Bool) {
        guard running else { return }
        guard integrator.set(sessionID, working: working, at: env.now()) else { return }
        if integrator.count == 0 {
            // Letzter Chat fertig: Timer aus, Ausstehendes gleich schreiben.
            flush()
        }
        updateTimer()
    }

    func handle(_ event: StatisticsSystemEvent) {
        guard running else { return }
        switch event {
        case .systemWillSleep:
            // Im Ruhezustand arbeitet kein Agent, auch wenn sein Status noch
            // „arbeitet“ sagt.
            integrator.suspend(at: env.now())
            flush()
        case .systemDidWake:
            integrator.resume(at: env.now())
        default:
            return
        }
        updateTimer()
    }

    func flush() {
        write(integrator.drain(at: env.now()))
    }

    private func write(_ segments: [StatisticsConcurrencyIntegrator.Segment]) {
        guard !segments.isEmpty else { return }
        let calendar = env.calendar
        store.update { db in StatisticsConcurrencyIntegrator.apply(segments, to: &db, calendar: calendar) }
    }

    private func updateTimer() {
        let needsTimer = running && integrator.count > 0 && !integrator.isSuspended
        if needsTimer, timer == nil, let interval = env.flushInterval {
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            }
            timer.tolerance = max(10, interval / 4)
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !needsTimer, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }
}
