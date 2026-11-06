import XCTest
@testable import WhisperM8

@MainActor
final class StatisticsCollectorsTests: XCTestCase {
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return cal
    }()

    private var directories: [URL] = []

    override func tearDown() {
        for dir in directories { try? FileManager.default.removeItem(at: dir) }
        directories = []
        super.tearDown()
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    private func makeStore() -> StatisticsStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stats-collect-\(UUID().uuidString)")
        directories.append(dir)
        return StatisticsStore(directory: dir, saveDelay: 30, notificationCenter: NotificationCenter())
    }

    /// Stellbare Uhr für die Tracker.
    private final class Clock {
        var now: Date
        var idle: TimeInterval = 0
        init(_ now: Date) { self.now = now }
    }

    private func activityTracker(store: StatisticsStore, clock: Clock, appActive: Bool = true) -> StatisticsActivityTracker {
        StatisticsActivityTracker(store: store, environment: .init(
            now: { clock.now },
            idleSeconds: { clock.idle },
            isAppActive: { appActive },
            calendar: { [calendar] in calendar },
            tickInterval: nil
        ))
    }

    private func agentTracker(store: StatisticsStore, clock: Clock) -> StatisticsAgentTracker {
        StatisticsAgentTracker(store: store, environment: .init(now: { clock.now }, calendar: { [calendar] in calendar }, flushInterval: nil))
    }

    // MARK: - Aktive Zeit

    func testBookingWithoutIdleCountsWholeInterval() {
        let booking = StatisticsActivityMath.booking(from: date(2026, 11, 5, 10), to: date(2026, 11, 5, 10, 1), idleSeconds: 3)
        XCTAssertEqual(booking.foreground?.duration, 60)
        XCTAssertEqual(booking.active?.duration, 60)
    }

    func testBookingCutsActiveTimeAfterIdleThreshold() {
        // Letzte Eingabe 6 Minuten vor Tick-Ende: aktiv nur bis Eingabe + 5 min,
        // also die erste der zwei Minuten.
        let start = date(2026, 11, 5, 10, 0)
        let end = date(2026, 11, 5, 10, 2)
        let booking = StatisticsActivityMath.booking(from: start, to: end, idleSeconds: 6 * 60)
        XCTAssertEqual(booking.foreground?.duration, 120)
        XCTAssertEqual(booking.active?.duration, 60)

        // Schon vor dem Intervall länger als 5 min still: gar nichts aktiv.
        XCTAssertNil(StatisticsActivityMath.booking(from: start, to: end, idleSeconds: 8 * 60).active)

        let partial = StatisticsActivityMath.booking(from: start, to: end, idleSeconds: 5 * 60 + 30)
        XCTAssertEqual(partial.active?.duration, 90)
    }

    func testBookingClampsLongGaps() {
        let booking = StatisticsActivityMath.booking(from: date(2026, 11, 5, 2), to: date(2026, 11, 5, 9), idleSeconds: 1)
        XCTAssertEqual(booking.foreground?.duration, StatisticsActivityMath.maxGap)
        XCTAssertEqual(booking.active?.duration, StatisticsActivityMath.maxGap)
    }

    func testActivityTrackerBooksTicksAndStopsOnResign() {
        let store = makeStore()
        let clock = Clock(date(2026, 11, 5, 10, 0))
        let tracker = activityTracker(store: store, clock: clock)
        tracker.start()
        XCTAssertTrue(tracker.isCounting)

        clock.now = date(2026, 11, 5, 10, 1)
        tracker.tick()
        clock.now = date(2026, 11, 5, 10, 1, 30)
        clock.idle = 10
        tracker.handle(.appResignedActive)
        XCTAssertFalse(tracker.isCounting)

        // Inaktiv: nichts mehr buchen, auch nicht bei einem Tick.
        clock.now = date(2026, 11, 5, 10, 30)
        tracker.tick()

        let day = store.snapshotSync().days["2026-11-05"]
        XCTAssertEqual(day?.foregroundSeconds, 90)
        XCTAssertEqual(day?.activeSeconds, 90)
        XCTAssertEqual(day?.hourlyActiveSeconds[10], 90)
    }

    func testActivityTrackerPausesOnLockAndSleep() {
        let store = makeStore()
        let clock = Clock(date(2026, 11, 5, 10, 0))
        let tracker = activityTracker(store: store, clock: clock)
        tracker.start()
        clock.now = date(2026, 11, 5, 10, 0, 40)
        tracker.handle(.screenLocked)
        XCTAssertFalse(tracker.isCounting)
        clock.now = date(2026, 11, 5, 10, 20)
        tracker.handle(.screenUnlocked)
        XCTAssertTrue(tracker.isCounting)
        clock.now = date(2026, 11, 5, 10, 20, 20)
        tracker.handle(.systemWillSleep)
        clock.now = date(2026, 11, 5, 11, 0)
        tracker.handle(.systemDidWake)
        clock.now = date(2026, 11, 5, 11, 0, 30)
        tracker.stop()

        XCTAssertEqual(store.snapshotSync().days["2026-11-05"]?.foregroundSeconds, 90)
    }

    func testActivityTrackerSplitsAtMidnight() {
        let store = makeStore()
        let clock = Clock(date(2026, 11, 5, 23, 59, 30))
        let tracker = activityTracker(store: store, clock: clock)
        tracker.start()
        clock.now = date(2026, 11, 6, 0, 0, 30)
        tracker.tick()
        let db = store.snapshotSync()
        XCTAssertEqual(db.days["2026-11-05"]?.activeSeconds, 30)
        XCTAssertEqual(db.days["2026-11-05"]?.hourlyActiveSeconds[23], 30)
        XCTAssertEqual(db.days["2026-11-06"]?.activeSeconds, 30)
        XCTAssertEqual(db.days["2026-11-06"]?.hourlyActiveSeconds[0], 30)
    }

    func testActivityTrackerWaitsForActivation() {
        let store = makeStore()
        let clock = Clock(date(2026, 11, 5, 10))
        let tracker = activityTracker(store: store, clock: clock, appActive: false)
        tracker.start()
        XCTAssertFalse(tracker.isCounting)
        tracker.handle(.screenLocked)
        // Wer die App nach vorne holt, hebt verpasste Sperr-Zustände auf.
        tracker.handle(.appBecameActive)
        XCTAssertTrue(tracker.isCounting)
    }

    // MARK: - Gleichzeitige Chats

    func testIntegratorAverageAndPeak() {
        var integrator = StatisticsConcurrencyIntegrator()
        let a = UUID(), b = UUID(), c = UUID()
        let t0 = date(2026, 11, 5, 10)
        integrator.set(a, working: true, at: t0)
        integrator.set(b, working: true, at: t0.addingTimeInterval(60))
        integrator.set(c, working: true, at: t0.addingTimeInterval(120))
        // Doppelte Meldung ändert nichts.
        XCTAssertFalse(integrator.set(c, working: true, at: t0.addingTimeInterval(130)))
        integrator.set(c, working: false, at: t0.addingTimeInterval(180))
        integrator.set(a, working: false, at: t0.addingTimeInterval(240))
        integrator.set(b, working: false, at: t0.addingTimeInterval(300))

        var db = StatsDatabase()
        StatisticsConcurrencyIntegrator.apply(integrator.drain(at: t0.addingTimeInterval(400)), to: &db, calendar: calendar)
        let day = try? XCTUnwrap(db.days["2026-11-05"])
        // 1×60 + 2×60 + 3×60 + 2×60 + 1×60 = 540 Chat-Sekunden in 300 s
        XCTAssertEqual(day?.agentWorkingSeconds, 300)
        XCTAssertEqual(day?.concurrencySeconds, 540)
        XCTAssertEqual(day?.peakConcurrent, 3)
        XCTAssertEqual(day?.hourlyAgentSeconds[10], 300)
    }

    func testIntegratorDrainSplitsOpenSegmentWithoutLoss() {
        var integrator = StatisticsConcurrencyIntegrator()
        let t0 = date(2026, 11, 5, 23, 59)
        integrator.set(UUID(), working: true, at: t0)
        integrator.set(UUID(), working: true, at: t0)
        var db = StatsDatabase()
        StatisticsConcurrencyIntegrator.apply(integrator.drain(at: t0.addingTimeInterval(30)), to: &db, calendar: calendar)
        StatisticsConcurrencyIntegrator.apply(integrator.drain(at: t0.addingTimeInterval(90)), to: &db, calendar: calendar)
        XCTAssertEqual(db.days["2026-11-05"]?.agentWorkingSeconds, 60)
        XCTAssertEqual(db.days["2026-11-05"]?.concurrencySeconds, 120)
        XCTAssertEqual(db.days["2026-11-06"]?.agentWorkingSeconds, 30)
        XCTAssertEqual(db.days["2026-11-06"]?.peakConcurrent, 2)
    }

    func testIntegratorSkipsSleep() {
        var integrator = StatisticsConcurrencyIntegrator()
        let t0 = date(2026, 11, 5, 10)
        integrator.set(UUID(), working: true, at: t0)
        integrator.suspend(at: t0.addingTimeInterval(60))
        XCTAssertTrue(integrator.drain(at: t0.addingTimeInterval(3600)).map(\.end) == [t0.addingTimeInterval(60)])
        integrator.resume(at: t0.addingTimeInterval(3600))
        let after = integrator.drain(at: t0.addingTimeInterval(3630))
        XCTAssertEqual(after.first?.start, t0.addingTimeInterval(3600))
        XCTAssertEqual(after.first.map { $0.end.timeIntervalSince($0.start) }, 30)
    }

    func testAgentTrackerWritesWhenLastChatStops() {
        let store = makeStore()
        let clock = Clock(date(2026, 11, 5, 10))
        let tracker = agentTracker(store: store, clock: clock)
        let id = UUID()
        // Vor dem Start wird nichts gezählt.
        tracker.setWorking(id, working: true)
        XCTAssertEqual(tracker.workingCount, 0)

        tracker.start()
        tracker.setWorking(id, working: true)
        clock.now = date(2026, 11, 5, 10, 2)
        tracker.setWorking(id, working: false)
        XCTAssertEqual(store.snapshotSync().days["2026-11-05"]?.agentWorkingSeconds, 120)

        // Beim Abschalten wird ein laufender Abschnitt abgeschlossen.
        tracker.setWorking(id, working: true)
        clock.now = date(2026, 11, 5, 10, 3)
        tracker.stop()
        XCTAssertEqual(store.snapshotSync().days["2026-11-05"]?.agentWorkingSeconds, 180)
        XCTAssertEqual(tracker.workingCount, 0)
    }

    // MARK: - Chats

    private func session(
        _ provider: AgentProvider = .claude,
        kind: AgentSessionKind? = nil,
        backend: String? = nil,
        project: UUID = UUID(),
        createdAt: Date = Date(),
        manual: Bool? = true
    ) -> AgentChatSession {
        AgentChatSession(
            provider: provider,
            projectID: project,
            title: "Test",
            createdAt: createdAt,
            createdManually: manual,
            kind: kind,
            claudeBackendModel: backend
        )
    }

    func testChatKindMapping() {
        XCTAssertEqual(StatisticsChatCounter.kind(of: session()), .claude)
        XCTAssertEqual(StatisticsChatCounter.kind(of: session(kind: .chat, backend: "gpt-6.1-sol")), .gpt)
        XCTAssertEqual(StatisticsChatCounter.kind(of: session(.codex)), .codex)
        XCTAssertEqual(StatisticsChatCounter.kind(of: session(kind: .backgroundChat)), .background)
        XCTAssertNil(StatisticsChatCounter.kind(of: session(kind: .terminal)))
        XCTAssertNil(StatisticsChatCounter.kind(of: session(kind: .agentView)))
        XCTAssertNil(StatisticsChatCounter.kind(of: session(.codex, kind: .subagentJob)))
        XCTAssertEqual(StatisticsChatCounter.projectName(forPath: "/Users/x/repos/whisperm8"), "whisperm8")
        XCTAssertEqual(StatisticsChatCounter.projectName(forPath: "/Users/x/repos/listm8/"), "listm8")
    }

    func testBackfillWithoutDoubleCounting() async {
        let store = makeStore()
        let counter = StatisticsChatCounter(store: store, calendar: calendar)
        let project = AgentProject(name: "WhisperM8", path: "/repos/whisperm8")
        let cutoff = date(2026, 11, 5, 12)
        let old = session(project: project.id, createdAt: date(2026, 11, 3, 9))
        let oldGPT = session(backend: "gpt-6.1-sol", project: project.id, createdAt: date(2026, 11, 3, 10))
        let imported = session(project: project.id, createdAt: date(2026, 11, 3, 11), manual: nil)
        let terminal = session(kind: .terminal, project: project.id, createdAt: date(2026, 11, 3, 12))
        let live = session(.codex, project: project.id, createdAt: date(2026, 11, 5, 13))
        let workspace = AgentWorkspace(projects: [project], sessions: [old, oldGPT, imported, terminal, live])

        // Der Live-Chat entsteht, bevor das Nachtragen fertig ist.
        counter.recordLive(live, projectPath: project.path)
        await counter.backfillIfNeeded(before: cutoff) { workspace }
        // Ein zweiter Start trägt nichts mehr nach.
        await counter.backfillIfNeeded(before: date(2026, 11, 6)) { workspace }

        let db = store.snapshotSync()
        XCTAssertTrue(db.chatsBackfilled)
        XCTAssertEqual(db.days["2026-11-03"]?.chatsStarted, ["claude": 1, "gpt": 1])
        XCTAssertEqual(db.days["2026-11-03"]?.projectChats, ["whisperm8": 2])
        XCTAssertEqual(db.days["2026-11-05"]?.chatsStarted, ["codex": 1])
        XCTAssertEqual(db.days["2026-11-05"]?.projectChats, ["whisperm8": 1])
    }

    func testLiveCounterPausesAfterResetUntilNextBackfill() async {
        let store = makeStore()
        let counter = StatisticsChatCounter(store: store, calendar: calendar)
        await counter.backfillIfNeeded(before: date(2026, 11, 5)) { .empty }
        store.reset()
        // Nach dem Löschen zählt der nächste Start diesen Chat aus `createdAt`.
        counter.recordLive(session(createdAt: date(2026, 11, 5, 10)), projectPath: "/repos/x")
        let db = store.snapshotSync()
        XCTAssertFalse(db.chatsBackfilled)
        XCTAssertNil(db.days["2026-11-05"])
    }

    // MARK: - Diktate

    func testWordCount() {
        XCTAssertEqual(StatisticsDictationRecorder.wordCount("Hallo Welt, wie geht's dir?"), 5)
        XCTAssertEqual(StatisticsDictationRecorder.wordCount("  \n — … "), 0)
        XCTAssertEqual(StatisticsDictationRecorder.countedText(rawText: "roh text", finalText: "  "), "roh text")
        XCTAssertEqual(StatisticsDictationRecorder.countedText(rawText: "roh", finalText: "fertig"), "fertig")
    }

    func testDictationRecordingSkipsFailed() {
        let store = makeStore()
        let at = date(2026, 11, 5, 9)
        StatisticsDictationRecorder.record(
            status: .succeeded, audioDuration: 12.5, rawText: "eins zwei drei", finalText: "Eins, zwei.",
            modeName: "Rewrite", at: at, store: store, calendar: calendar
        )
        StatisticsDictationRecorder.record(
            status: .rawFallback, audioDuration: 4, rawText: "vier", finalText: nil,
            modeName: "Rewrite", at: at, store: store, calendar: calendar
        )
        StatisticsDictationRecorder.record(
            status: .failed, audioDuration: 99, rawText: "fehler", finalText: nil,
            modeName: "Email", at: at, store: store, calendar: calendar
        )
        let day = store.snapshotSync().days["2026-11-05"]
        XCTAssertEqual(day?.dictations, 2)
        XCTAssertEqual(day?.dictationAudioSeconds, 16.5)
        XCTAssertEqual(day?.dictationWords, 3)
        XCTAssertEqual(day?.dictationModes, ["Rewrite": 2])
    }

    func testHooksAreNoOpsWhileCollectorsAreStopped() {
        XCTAssertFalse(StatisticsCollectors.gate.isOpen)
        // Darf in Tests nichts anfassen (kein Store-Zugriff, kein Absturz).
        StatisticsCollectors.noteChatCreated(session(), projectPath: "/repos/x")
        StatisticsCollectors.noteAgentStatus(.working, for: UUID())
        StatisticsCollectors.start()
        XCTAssertFalse(StatisticsCollectors.gate.isOpen)
    }

    // MARK: - Schalter und Notbremse

    func testRuntimeForwardsOnlyRealChanges() {
        StatisticsRuntime.resetForTesting()
        defer { StatisticsRuntime.resetForTesting() }
        var received: [Bool] = []
        StatisticsRuntime.onEnabledChanged { received.append($0) }
        StatisticsRuntime.setInitialEnabled(true)

        StatisticsRuntime.notifyEnabledChanged(true)   // kein Wechsel
        StatisticsRuntime.notifyEnabledChanged(false)  // Beobachter
        StatisticsRuntime.notifyEnabledChanged(false)  // Seitenschalter, doppelt
        StatisticsRuntime.notifyEnabledChanged(true)
        XCTAssertEqual(received, [false, true])
    }

    /// `defaults write … statisticsEnabled -bool NO` wirkt ohne Neustart.
    func testDefaultsObserverReportsSwitchOnceAfterDebounce() throws {
        let suite = "statistics-enabled-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var received: [Bool] = []
        let off = expectation(description: "aus")
        let observer = StatisticsEnabledObserver(defaults: defaults, debounce: 0.05) { value in
            received.append(value)
            if value == false { off.fulfill() }
        }
        observer.start()
        defer { observer.stop() }

        // Mehrfaches Setzen kurz hintereinander: eine Meldung.
        defaults.set(true, forKey: StatisticsPreferenceKeys.enabled)
        defaults.set(false, forKey: StatisticsPreferenceKeys.enabled)
        defaults.set(false, forKey: StatisticsPreferenceKeys.enabled)
        wait(for: [off], timeout: 2)
        XCTAssertEqual(received, [false])

        let on = expectation(description: "an")
        let observer2 = StatisticsEnabledObserver(defaults: defaults, debounce: 0.05) { value in
            if value { on.fulfill() }
        }
        observer2.start()
        defer { observer2.stop() }
        defaults.set(true, forKey: StatisticsPreferenceKeys.enabled)
        wait(for: [on], timeout: 2)
        XCTAssertEqual(received, [false, true])
    }
}
