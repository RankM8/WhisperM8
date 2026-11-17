import XCTest
@testable import WhisperM8

/// WM8-110 Paket 3: Alte Lauf-Ordner gehen ins Archiv, ein arbeitender Lauf
/// und die jüngsten drei bleiben stehen.
final class ScheduledTaskArchiveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func date(_ text: String) -> Date { ScheduledTaskCalendarTests.date(text) }

    /// Legt einen fertigen Lauf an, angelegt zu `created`.
    @discardableResult
    private func writeRun(_ store: ScheduledTaskStore, task: UUID, created: Date, pid: Int32? = nil,
                          finished: Bool = true) throws -> String {
        let runID = ScheduledTaskRunRecord.makeRunID(now: created)
        let directory = store.runsDirectory(for: task).appendingPathComponent(runID, isDirectory: true)
        let record = ScheduledTaskRunRecord(runID: runID, taskID: task, taskName: "T", sessionID: UUID(), account: "main",
                                            directory: "/tmp", trigger: .schedule, slot: created, createdAt: created, pid: pid)
        try store.writeRecord(record, in: directory)
        if finished {
            try "0 \(Int(created.timeIntervalSince1970) + 60)\n".write(
                to: directory.appendingPathComponent("exit"), atomically: true, encoding: .utf8)
        }
        return runID
    }

    func testOldRunsMoveKeepingTheNewestThreeAndActiveOnes() throws {
        let store = ScheduledTaskStore(root: root)
        let task = UUID()
        let old1 = try writeRun(store, task: task, created: date("2026-10-01 07:00"))
        let active = try writeRun(store, task: task, created: date("2026-10-02 07:00"), pid: 4242, finished: false)
        let old2 = try writeRun(store, task: task, created: date("2026-10-03 07:00"))
        for day in 4...6 { try writeRun(store, task: task, created: date("2026-10-0\(day) 07:00")) }

        let moved = store.archiveRuns(of: task, olderThan: date("2026-11-01 00:00"), keepNewest: 3) { files in
            ScheduledTaskRunEvaluator.outcome(of: files, isProcessAlive: { pid, _ in pid == 4242 }).isActive
        }
        XCTAssertEqual(moved, 2, "nur die zwei alten, fertigen")
        let left = store.runDirectories(for: task).map(\.lastPathComponent)
        XCTAssertEqual(left.count, 4)
        XCTAssertTrue(left.contains(active), "ein arbeitender Lauf bleibt")
        XCTAssertFalse(left.contains(old1))
        XCTAssertFalse(left.contains(old2))
        XCTAssertEqual(store.archivedRunCount(for: task), 2)
        XCTAssertNotNil(store.readRun(at: store.archiveDirectory(for: task).appendingPathComponent(old1)),
                        "im Archiv vollständig lesbar")
    }

    func testRecentRunsStay() throws {
        let store = ScheduledTaskStore(root: root)
        let task = UUID()
        for day in 1...5 { try writeRun(store, task: task, created: date("2026-11-1\(day) 07:00")) }
        let moved = store.archiveRuns(of: task, olderThan: date("2026-11-03 00:00"), keepNewest: 3) { _ in false }
        XCTAssertEqual(moved, 0)
        XCTAssertEqual(ScheduledTaskStore.creationDate(ofRunNamed: "20261117T060000Z-ab12cd"), date("2026-11-17 07:00"))
        XCTAssertNil(ScheduledTaskStore.creationDate(ofRunNamed: ".DS_Store"))
    }

    // MARK: Einstellung

    func testArchiveDaysFromCLIFormAndValidation() throws {
        let add = try ScheduleCLIArguments.parseDraft(["--archive-runs", "never"], forAdd: true)
        XCTAssertEqual(add.draft.runArchiveDays, 0)
        XCTAssertEqual(try ScheduleCLIArguments.parseDraft(["--archive-runs", "7"], forAdd: false).draft.runArchiveDays, 7)
        XCTAssertThrowsError(try ScheduleCLIArguments.parseDraft(["--archive-runs", "30"], forAdd: false))

        var task = ScheduledTask(name: "T", prompt: "p", directory: "/tmp", account: "main",
                                 schedule: ScheduledTaskSchedule(kind: .daily, times: [ScheduledTaskClockTime(hour: 7, minute: 0)!]),
                                 createdAt: Date())
        XCTAssertEqual(task.runArchiveDays, 14, "ab Werk 14 Tage")
        task.runArchiveDays = 30
        XCTAssertEqual(ScheduledTaskValidation.problem(in: task, others: [], directoryExists: { _ in true }, accountExists: { _ in true }),
                       .invalidArchiveDays)

        task.runArchiveDays = 14
        var form = ScheduledTaskEditorForm(task: task)
        XCTAssertNil(try form.draft(original: task).get().runArchiveDays, "unverändert: nicht im Entwurf")
        form.runArchiveDays = 0
        XCTAssertEqual(try form.draft(original: task).get().runArchiveDays, 0)
    }

    func testOldFileWithoutFieldDecodesWithDefault() throws {
        let json = #"{"version":1,"tasks":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"T","prompt":"p","directory":"/tmp","account":"main","schedule":{"kind":"daily","times":["07:00"]},"createdAt":"2026-11-01T08:00:00Z"}]}"#
        let file = try ScheduledTaskStore.makeDecoder().decode(ScheduledTasksFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.tasks.first?.runArchiveDays, 14)
    }

    // MARK: Prüfung Mara K4

    func testExistingTargetGetsANumberAndCountIsWritten() throws {
        let store = ScheduledTaskStore(root: root)
        let task = UUID()
        let old = try writeRun(store, task: task, created: date("2026-10-01 07:00"))
        // Gleichnamiger Ordner liegt schon im Archiv.
        try FileManager.default.createDirectory(at: store.archiveDirectory(for: task).appendingPathComponent(old),
                                                withIntermediateDirectories: true)
        let moved = store.archiveRuns(of: task, olderThan: date("2026-11-01 00:00"), keepNewest: 0) { _ in false }
        XCTAssertEqual(moved, 1, "kein Fehler bei jedem Durchgang")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.archiveDirectory(for: task).appendingPathComponent(old + "-2").path))
        XCTAssertTrue(store.runDirectories(for: task).isEmpty)
        XCTAssertEqual(store.archivedRunCount(for: task), 1, "Zahl aus .count, ohne Listing")
        try writeRun(store, task: task, created: date("2026-10-02 07:00"))
        store.archiveRuns(of: task, olderThan: date("2026-11-01 00:00"), keepNewest: 0) { _ in false }
        XCTAssertEqual(store.archivedRunCount(for: task), 2)
    }
}
