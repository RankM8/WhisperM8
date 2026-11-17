import XCTest
@testable import WhisperM8

/// WM8-110 Paket 3: Mitteilung bei Fehlschlag — wann sie kommt, wohin ein
/// Klick führt.
final class ScheduledTaskFailureNoticeTests: XCTestCase {
    typealias Fake = ScheduledTaskSchedulerTests.Fake

    /// Gesammelte Mitteilungen der Attrappe.
    final class Notices: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ScheduledTaskFailureNotice] = []

        func append(_ notice: ScheduledTaskFailureNotice) {
            lock.lock()
            items.append(notice)
            lock.unlock()
        }

        var all: [ScheduledTaskFailureNotice] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    private var root: URL!
    private var projectDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("notice-\(UUID().uuidString)", isDirectory: true)
        projectDir = root.appendingPathComponent("projekt", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func date(_ text: String) -> Date { ScheduledTaskCalendarTests.date(text) }

    private func makeScheduler(_ fake: Fake, notices: Notices) -> (ScheduledTaskScheduler, ScheduledTaskStore) {
        let store = ScheduledTaskStore(root: root.appendingPathComponent("support", isDirectory: true))
        let env = ScheduledTaskScheduler.Environment(
            store: store,
            now: { fake.now },
            calendar: { ScheduledTaskCalendarTests.calendar },
            isEnabled: { fake.enabled },
            claudePath: { "/usr/local/bin/claude" },
            accountEnvironment: { fake.accounts.contains($0) ? [:] : nil },
            baseEnvironment: { ["PATH": "/usr/bin:/bin"] },
            authStatus: { _, _, _ in fake.auth },
            supportsNativeName: { true },
            directoryExists: { FileManager.default.fileExists(atPath: $0) },
            spawn: { plan in
                fake.plans.append(plan)
                fake.nextPID += 1
                fake.alivePIDs.insert(fake.nextPID)
                return fake.nextPID
            },
            processStartTime: { _ in fake.now },
            isProcessAlive: { pid, _ in fake.alivePIDs.contains(pid) },
            watchExit: { pid, handler in fake.exitHandlers[pid] = handler },
            notifyFailure: { notices.append($0) }
        )
        return (ScheduledTaskScheduler(environment: env), store)
    }

    private func draft() -> ScheduledTaskDraft {
        guard case .success(let schedule) = ScheduledTaskSchedule.parse("täglich 07:00") else { fatalError() }
        return ScheduledTaskDraft(name: "Bericht", prompt: "Schreib den Bericht.", directory: projectDir.path,
                                  account: "main", schedule: schedule)
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: Wann

    func testFailedRunNotifiesOnceWithItsChat() async throws {
        let fake = Fake(now: date("2026-11-16 12:00"))
        let notices = Notices()
        let (scheduler, store) = makeScheduler(fake, notices: notices)
        await scheduler.start()
        let task = try await scheduler.add(draft())
        fake.now = date("2026-11-17 07:01")
        await scheduler.evaluate(reason: "test")

        let run = try XCTUnwrap(store.recentRuns(for: task.id, limit: 1).first)
        let pid = try XCTUnwrap(run.record.pid)
        try #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Login abgelaufen."}"#
            .write(to: run.directory.appendingPathComponent("result.json"), atomically: true, encoding: .utf8)
        try "1 1763362800\n".write(to: run.directory.appendingPathComponent("exit"), atomically: true, encoding: .utf8)
        fake.alivePIDs.remove(pid)
        fake.exitHandlers[pid]?()
        await waitFor { !notices.all.isEmpty }

        XCTAssertEqual(notices.all.count, 1)
        let notice = try XCTUnwrap(notices.all.first)
        XCTAssertEqual(notice.taskID, task.id)
        XCTAssertEqual(notice.taskName, "Bericht")
        XCTAssertEqual(notice.sessionID, run.record.sessionID, "Knopf „Zum Chat“ kennt die Sitzung")
        XCTAssertEqual(notice.outcome, .failed(message: "Login abgelaufen."))
    }

    func testSuccessfulRunStaysQuiet() async throws {
        let fake = Fake(now: date("2026-11-16 12:00"))
        let notices = Notices()
        let (scheduler, store) = makeScheduler(fake, notices: notices)
        await scheduler.start()
        let task = try await scheduler.add(draft())
        fake.now = date("2026-11-17 07:01")
        await scheduler.evaluate(reason: "test")
        let run = try XCTUnwrap(store.recentRuns(for: task.id, limit: 1).first)
        let pid = try XCTUnwrap(run.record.pid)
        try #"{"type":"result","subtype":"success","is_error":false,"result":"Fertig."}"#
            .write(to: run.directory.appendingPathComponent("result.json"), atomically: true, encoding: .utf8)
        try "0 1763362800\n".write(to: run.directory.appendingPathComponent("exit"), atomically: true, encoding: .utf8)
        fake.alivePIDs.remove(pid)
        fake.exitHandlers[pid]?()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(notices.all.isEmpty)
    }

    func testNotStartedAtItsSlotNotifiesButNotByHand() async throws {
        let fake = Fake(now: date("2026-11-16 12:00"))
        let notices = Notices()
        let (scheduler, _) = makeScheduler(fake, notices: notices)
        await scheduler.start()
        let task = try await scheduler.add(draft())
        fake.auth = .init(loggedIn: false, loginExpiresAt: nil)

        _ = try await scheduler.runNow(id: task.id)
        XCTAssertTrue(notices.all.isEmpty, "von Hand: Ansicht und CLI melden es selbst")

        fake.now = date("2026-11-17 07:01")
        await scheduler.evaluate(reason: "test")
        XCTAssertEqual(notices.all.count, 1)
        XCTAssertNil(notices.all.first?.sessionID, "nicht gestartet: kein Chat")
        guard case .notStarted(.loginExpired, _) = notices.all.first?.outcome else {
            return XCTFail("\(String(describing: notices.all.first?.outcome))")
        }
    }

    func testMissedAndSkippedAreNoFailure() {
        let record = ScheduledTaskRunRecord(runID: "r", taskID: UUID(), taskName: "T", sessionID: nil, account: "main",
                                            directory: "/tmp", trigger: .schedule, slot: nil, createdAt: Date())
        XCTAssertNil(ScheduledTaskFailureNotice(record: record, outcome: .notStarted(.missed, message: nil)))
        XCTAssertNil(ScheduledTaskFailureNotice(record: record, outcome: .notStarted(.stillRunning, message: nil)))
        XCTAssertNil(ScheduledTaskFailureNotice(record: record, outcome: .succeededWithNotes(summary: nil, deniedTools: ["Bash"])))
        XCTAssertNotNil(ScheduledTaskFailureNotice(record: record, outcome: .aborted))
    }

    // MARK: Wohin

    func testClickRoutes() {
        let task = UUID()
        let session = UUID()
        let info: [AnyHashable: Any] = [ScheduledTaskNotifications.taskIDKey: task.uuidString,
                                        ScheduledTaskNotifications.sessionIDKey: session.uuidString]
        XCTAssertEqual(ScheduledTaskNotifications.route(userInfo: info, actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier"),
                       .task(task), "Klick auf die Mitteilung: Detail")
        XCTAssertEqual(ScheduledTaskNotifications.route(userInfo: info, actionIdentifier: ScheduledTaskNotifications.openChatAction),
                       .chat(session: session, task: task))
        XCTAssertEqual(ScheduledTaskNotifications.route(userInfo: info, actionIdentifier: ScheduledTaskNotifications.showTaskAction),
                       .task(task))
        XCTAssertNil(ScheduledTaskNotifications.route(userInfo: ["localSessionID": session.uuidString], actionIdentifier: ""),
                     "fremde Mitteilungen bleiben beim alten Weg")
    }

    // MARK: Archiv im Durchlauf (gleiche Attrappe)

    func testEvaluateArchivesOldRunsAtMostHourly() async throws {
        let fake = Fake(now: date("2026-11-01 12:00"))
        let (scheduler, store) = makeScheduler(fake, notices: Notices())
        await scheduler.start()
        var short = draft()
        short.runArchiveDays = 7
        let task = try await scheduler.add(short)
        // Fünf fertige Läufe am 1. bis 5. November.
        for day in 1...5 {
            let created = date("2026-11-0\(day) 07:00")
            let runID = ScheduledTaskRunRecord.makeRunID(now: created)
            let dir = store.runsDirectory(for: task.id).appendingPathComponent(runID, isDirectory: true)
            try store.writeRecord(ScheduledTaskRunRecord(runID: runID, taskID: task.id, taskName: "Bericht", sessionID: UUID(),
                                                         account: "main", directory: projectDir.path, trigger: .schedule,
                                                         slot: created, createdAt: created, pid: 1), in: dir)
            try "0 0\n".write(to: dir.appendingPathComponent("exit"), atomically: true, encoding: .utf8)
        }
        fake.now = date("2026-11-10 06:00")
        await scheduler.evaluate(reason: "test")
        XCTAssertEqual(store.archivedRunCount(for: task.id), 2, "1. und 2. November; die jüngsten drei bleiben")
        // Stehen bleiben: der verpasste Termin vom 9., die Läufe vom 5. und 4. (jüngste drei)
        // und der vom 3. (07:00, noch keine 7 Tage vor dem 10., 06:00).
        XCTAssertEqual(store.runDirectories(for: task.id).count, 4)

        // Eine Stunde lang kein zweiter Durchgang, danach wieder.
        fake.now = date("2026-11-10 06:30")
        await scheduler.evaluate(reason: "test")
        XCTAssertEqual(store.archivedRunCount(for: task.id), 2)
        fake.now = date("2026-11-10 07:30")
        await scheduler.evaluate(reason: "test")
        XCTAssertEqual(store.archivedRunCount(for: task.id), 3, "jetzt ist der 3. älter als 7 Tage")
    }
}
