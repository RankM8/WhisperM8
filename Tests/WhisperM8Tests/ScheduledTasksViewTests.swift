import Foundation
import XCTest
@testable import WhisperM8

/// Ansicht „Geplant“ (WM8-110, Paket 2): Formular, Texte, Zustand, Laden und
/// das Detail je Fenster.
@MainActor
final class ScheduledTasksViewTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wm8-geplant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = berlin.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private func task(_ name: String = "Probe", schedule: ScheduledTaskSchedule? = nil, paused: Bool = false,
                      permissions: ScheduledTaskPermissions = .init()) -> ScheduledTask {
        ScheduledTask(name: name, prompt: "Prüfe etwas.", directory: "/tmp", account: "main",
                      schedule: schedule ?? ScheduledTaskSchedule(kind: .daily, times: [ScheduledTaskClockTime(hour: 7, minute: 0)!]),
                      permissions: permissions, paused: paused, createdAt: date("2026-11-01 08:00"))
    }

    // MARK: Formular

    func testExtraToolsSplitOnCommasOutsideParentheses() {
        var form = ScheduledTaskEditorForm()
        form.extraToolsText = "Bash(git log, status), mcp__linear__get_issue\nWebSearch, ,"
        XCTAssertEqual(form.extraTools, ["Bash(git log, status)", "mcp__linear__get_issue", "WebSearch"])
    }

    func testScheduleFromFields() throws {
        var form = ScheduledTaskEditorForm()
        form.kind = .weekly
        form.timesText = "22:30, 7:00"
        form.days = [3, 1]
        let schedule = try form.schedule().get()
        XCTAssertEqual(schedule.text, "wöchentlich Mo, Mi 07:00, 22:30")

        form.days = []
        XCTAssertThrowsError(try form.schedule().get(), "wöchentlich ohne Tag")
        form.kind = .daily
        form.timesText = "7 Uhr"
        XCTAssertThrowsError(try form.schedule().get())
        form.timesText = " "
        XCTAssertThrowsError(try form.schedule().get())

        form.kind = .hourly
        form.minuteText = ":15"
        XCTAssertEqual(try form.schedule().get(), ScheduledTaskSchedule(kind: .hourly, minute: 15))
        form.minuteText = "60"
        XCTAssertThrowsError(try form.schedule().get())
    }

    func testProblemsMatchTheCommandLineRules() {
        var form = ScheduledTaskEditorForm()
        let exists: (String) -> Bool = { $0 == "/tmp" }
        XCTAssertNotNil(form.problem(others: [], accounts: ["main"], directoryExists: exists), "Name fehlt")
        form.name = "probe"
        form.prompt = "Prüfe etwas."
        form.directory = "/tmp"
        XCTAssertNotNil(form.problem(others: [task("Probe")], accounts: ["main"], directoryExists: exists),
                        "Name doppelt, ohne Groß- und Kleinschreibung")
        XCTAssertNil(form.problem(others: [], accounts: ["main"], directoryExists: exists))
        form.prompt = "--dangerously-skip-permissions"
        XCTAssertNotNil(form.problem(others: [], accounts: ["main"], directoryExists: exists))
        form.prompt = "ok"
        form.account = "Weg"
        XCTAssertNotNil(form.problem(others: [], accounts: ["main"], directoryExists: exists))
        XCTAssertNil(form.problem(others: [], accounts: nil, directoryExists: exists), "Konten noch nicht geladen: der Planer prüft")
        form.account = "main"
        form.directory = "/gibt-es-nicht"
        XCTAssertNotNil(form.problem(others: [], accounts: ["main"], directoryExists: exists))
        form.directory = "/tmp"
        form.access = .custom
        XCTAssertNotNil(form.problem(others: [], accounts: ["main"], directoryExists: exists), "eigene Liste leer")
        form.extraToolsText = "--allow-all"
        XCTAssertNotNil(form.problem(others: [], accounts: ["main"], directoryExists: exists))
    }

    func testDraftCarriesOnlyChangedFields() throws {
        let original = task(permissions: ScheduledTaskPermissions(access: .readOnly, extraTools: ["WebSearch"]))
        var form = ScheduledTaskEditorForm(task: original)
        XCTAssertTrue(try form.draft(original: original).get().isEmpty, "unverändert: nichts senden, lastSlot bleibt")

        form.timesText = "07:00"
        XCTAssertNil(try form.draft(original: original).get().schedule, "gleiche Uhrzeit, anders geschrieben")
        form.name = "Neu"
        form.extraToolsText = ""
        let draft = try form.draft(original: original).get()
        XCTAssertEqual(draft.name, "Neu")
        XCTAssertEqual(draft.extraTools, [])
        XCTAssertNil(draft.access)
        XCTAssertNil(draft.prompt)

        let fresh = try ScheduledTaskEditorForm().draft(original: nil).get()
        XCTAssertNotNil(fresh.schedule, "neue Aufgabe: alle Felder")
        XCTAssertEqual(fresh.catchUp, true)
    }

    // MARK: Texte

    func testPermissionTextNamesOnlyWhatIsStillBlocked() {
        XCTAssertEqual(ScheduledTaskTexts.blockedFamilies(ScheduledTaskPermissions(access: .projectWrite)), ["Bash", "web", "MCP"])
        let bash = ScheduledTaskPermissions(access: .readOnly, extraTools: ["Bash(git log *)"])
        XCTAssertEqual(ScheduledTaskTexts.blockedFamilies(bash), ["web", "MCP"])
        XCTAssertTrue(ScheduledTaskTexts.permissions(bash).contains("Bash(git log *)"))
        let all = ScheduledTaskPermissions(access: .custom, extraTools: ["Bash", "WebFetch", "WebSearch", "mcp__x__y"])
        XCTAssertEqual(ScheduledTaskTexts.blockedFamilies(all), [])
        XCTAssertTrue(ScheduledTaskTexts.permissions(ScheduledTaskPermissions(access: .readOnly)).contains("whole disk"),
                      "Lesen gilt für die ganze Platte, das steht da")
    }

    func testTimesAreFixedNotCountingDown() {
        let clock = ScheduledTaskTexts.Clock(now: date("2026-11-16 15:50"), calendar: berlin, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(ScheduledTaskTexts.nextShort(date("2026-11-16 17:30"), clock: clock), "17:30")
        XCTAssertEqual(ScheduledTaskTexts.nextShort(date("2026-11-17 07:00"), clock: clock), "tomorrow 07:00")
        XCTAssertTrue(ScheduledTaskTexts.nextShort(date("2026-11-19 07:00"), clock: clock).hasSuffix(" 07:00"))
        XCTAssertFalse(ScheduledTaskTexts.nextShort(date("2026-11-30 07:00"), clock: clock).contains("07:00"))
        XCTAssertEqual(ScheduledTaskTexts.runShort(date("2026-11-16 07:00"), clock: clock), "today 07:00")
        XCTAssertEqual(ScheduledTaskTexts.runShort(date("2026-11-15 22:30"), clock: clock), "yesterday 22:30")
        XCTAssertEqual(ScheduledTaskTexts.dateTime(date("2026-11-17 07:00"), clock: clock), "tomorrow, 07:00")
    }

    // MARK: Zustand

    func testStatePrefersWorkingThenPausedAndIgnoresMissed() {
        let now = date("2026-11-16 12:00")
        func run(_ outcome: ScheduledTaskRunOutcome) -> ScheduledTaskRunSummary {
            ScheduledTaskRunSummary(id: UUID().uuidString, createdAt: now, sessionID: UUID(), outcome: outcome)
        }
        XCTAssertEqual(ScheduledTaskOverview.state(paused: true, runs: [run(.running)]), .running)
        XCTAssertEqual(ScheduledTaskOverview.state(paused: true, runs: [run(.failed(message: "x"))]), .paused)
        XCTAssertEqual(ScheduledTaskOverview.state(paused: false, runs: []), .scheduled)
        XCTAssertEqual(ScheduledTaskOverview.state(paused: false, runs: [
            run(.notStarted(.missed, message: nil)), run(.failed(message: "x")),
        ]), .failed, "verpasst verdeckt den Fehler davor nicht")
        XCTAssertEqual(ScheduledTaskOverview.state(paused: false, runs: [run(.notStarted(.loginExpired, message: nil))]), .failed)
        XCTAssertEqual(ScheduledTaskOverview.state(paused: false, runs: [
            run(.succeededWithNotes(summary: nil, deniedTools: ["Write"])),
        ]), .succeededWithNotes)
    }

    // MARK: Laden

    func testLoaderReadsTasksRunsAndNextDate() throws {
        let store = ScheduledTaskStore(root: root)
        let active = task("Aktiv")
        let resting = task("Ruht", paused: true)
        try store.save(ScheduledTasksFile(tasks: [active, resting]))
        func write(_ task: ScheduledTask, at: String, pid: Int32?, exit: String?) throws {
            let created = date(at)
            let record = ScheduledTaskRunRecord(
                runID: ScheduledTaskRunRecord.makeRunID(now: created), taskID: task.id, taskName: task.name,
                sessionID: UUID(), account: "main", directory: "/tmp", trigger: .schedule, slot: created,
                createdAt: created, pid: pid, processStartedAt: created)
            let directory = store.runsDirectory(for: task.id).appendingPathComponent(record.runID)
            try store.writeRecord(record, in: directory)
            if let exit {
                try exit.write(to: directory.appendingPathComponent("exit"), atomically: true, encoding: .utf8)
                try #"{"is_error":false,"result":"Fertig."}"#.write(
                    to: directory.appendingPathComponent("result.json"), atomically: true, encoding: .utf8)
            }
        }
        try write(active, at: "2026-11-15 07:00", pid: 10, exit: "0 \(Int(date("2026-11-15 07:03").timeIntervalSince1970))")
        try write(active, at: "2026-11-16 07:00", pid: 4242, exit: nil)

        let snapshot = ScheduledTaskOverviewLoader.load(
            store: store, now: date("2026-11-16 07:01"), calendar: berlin,
            isProcessAlive: { pid, _ in pid == 4242 })
        XCTAssertNil(snapshot.loadError)
        let overview = try XCTUnwrap(snapshot.overviews.first { $0.task.name == "Aktiv" })
        XCTAssertEqual(overview.state, .running)
        XCTAssertEqual(overview.runs.count, 2)
        XCTAssertEqual(overview.runs.first?.outcome, .running, "neueste zuerst")
        XCTAssertEqual(overview.runs.last?.outcome, .succeeded(summary: "Fertig."))
        XCTAssertEqual(overview.runs.last?.durationSeconds, 180)
        XCTAssertEqual(overview.next, date("2026-11-17 07:00"))
        let paused = try XCTUnwrap(snapshot.overviews.first { $0.task.name == "Ruht" })
        XCTAssertNil(paused.next)
        XCTAssertEqual(paused.state, .paused)
    }

    func testLoaderReportsUnreadableFile() throws {
        let store = ScheduledTaskStore(root: root)
        try "kaputt".write(to: store.fileURL, atomically: true, encoding: .utf8)
        let snapshot = ScheduledTaskOverviewLoader.load(store: store, now: Date(), calendar: berlin, isProcessAlive: { _, _ in false })
        XCTAssertNotNil(snapshot.loadError)
        XCTAssertTrue(snapshot.overviews.isEmpty)
    }

    func testModelKeepsSnapshotWhenNothingChangedAndReportsDisabled() async {
        let model = ScheduledTasksOverviewModel(dependencies: .init(load: { .init() }, scheduler: { nil }, afterChange: {}))
        XCTAssertFalse(model.hasLoaded)
        let snapshot = ScheduledTaskOverviewLoader.Snapshot(overviews: [
            ScheduledTaskOverview(task: task(), next: nil, runs: [], state: .scheduled),
        ])
        model.apply(snapshot)
        XCTAssertTrue(model.hasLoaded)
        XCTAssertEqual(model.snapshot, snapshot)
        let message = await model.runNow(UUID())
        XCTAssertEqual(message, ScheduledTaskTexts.schedulerError(.disabled),
                       "Schalter aus: kein Start, klare Meldung")
    }

    // MARK: Detail je Fenster

    private func makeWindowStore() -> AgentWindowStore {
        func url(_ prefix: String) -> URL { root.appendingPathComponent("\(prefix)-\(UUID().uuidString).json") }
        return AgentWindowStore(persistence: AgentSessionStore(fileURL: url("ws"), uiStateFileURL: url("ui")))
    }

    func testDetailClosesOnNavigationAndTickets() {
        let store = makeWindowStore()
        let window = store.primaryWindowID
        let other = UUID()
        let taskID = UUID()

        store.setTicketsMode(true, in: window)
        store.showScheduledTask(taskID, in: window)
        XCTAssertEqual(store.scheduledTaskDetail(in: window), taskID)
        XCTAssertFalse(store.isTicketsMode(in: window), "Detail ersetzt die Tickets")
        XCTAssertNil(store.scheduledTaskDetail(in: other), "je Fenster")

        store.navigateToSession(UUID(), in: window)
        XCTAssertNil(store.scheduledTaskDetail(in: window), "Klick auf einen Chat schließt das Detail")

        store.showScheduledTask(taskID, in: window)
        store.keepingTicketsMode { store.navigateToSession(UUID(), in: window) }
        XCTAssertEqual(store.scheduledTaskDetail(in: window), taskID, "Auswahl aus dem Steuerkanal lässt es stehen")

        store.setTicketsMode(true, in: window)
        XCTAssertNil(store.scheduledTaskDetail(in: window), "Tickets ersetzen das Detail")

        store.showScheduledTask(taskID, in: window)
        store.forgetTickets(of: window)
        XCTAssertNil(store.scheduledTaskDetail(in: window), "Fenster zu: vergessen")
    }

    /// Prüfung M1/M2: Das Detail verdeckt den Chat wie die Tickets. Controller,
    /// Diktat und ⌘W dürfen den gewählten Chat dahinter nicht treffen.
    func testDetailHidesTheChatBehindIt() {
        let store = makeWindowStore()
        let window = store.primaryWindowID
        let chat = UUID()
        store.navigateToSession(chat, in: window)
        XCTAssertFalse(store.hidesChatContent(in: window))
        let snapshot = AgentChatsWindowSnapshot(
            windowID: window, isKeyWindow: true, selectedSessionID: chat, isGridActive: true, canReturnToWorkspace: true,
            isSwitcherOpen: false, hasSheet: false, isSidebarVisible: true, hasMultiSelection: false, isArchiveMode: false)
        XCTAssertEqual(snapshot.hidingChats(store.hidesChatContent(in: window)).selectedSessionID, chat)

        store.showScheduledTask(UUID(), in: window)
        XCTAssertTrue(store.hidesChatContent(in: window))
        let hidden = snapshot.hidingChats(store.hidesChatContent(in: window))
        XCTAssertNil(hidden.selectedSessionID, "kein Ziel für Bestätigen, Abbrechen und Diktat")
        XCTAssertFalse(hidden.isGridActive)
        XCTAssertEqual(store.selectedSession(in: window), chat, "der Tab dahinter bleibt gewählt")

        store.closeScheduledTask(in: window)
        store.setTicketsMode(true, in: window)
        XCTAssertTrue(store.hidesChatContent(in: window), "Tickets verdecken ebenso")
    }

    /// Prüfung K3: Nach dem Anlegen steht die Aufgabe sofort in der Übersicht,
    /// nicht erst nach dem Laden („gibt es nicht mehr“ im Detail).
    func testSavedTaskShowsBeforeReload() {
        let model = ScheduledTasksOverviewModel(dependencies: .init(load: { .init() }, scheduler: { nil }, afterChange: {}))
        let created = task("Neu")
        model.insertOrReplace(created, now: date("2026-11-16 12:00"), calendar: berlin)
        XCTAssertTrue(model.hasLoaded)
        XCTAssertEqual(model.overview(id: created.id)?.next, date("2026-11-17 07:00"))

        var renamed = created
        renamed.name = "Umbenannt"
        renamed.paused = true
        model.insertOrReplace(renamed, now: date("2026-11-16 12:00"), calendar: berlin)
        XCTAssertEqual(model.snapshot.overviews.count, 1)
        XCTAssertEqual(model.overview(id: created.id)?.task.name, "Umbenannt")
        XCTAssertEqual(model.overview(id: created.id)?.state, .paused)
        XCTAssertNil(model.overview(id: created.id)?.next)
    }
}
