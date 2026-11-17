import XCTest
@testable import WhisperM8

/// WM8-110 Paket 1: `whisperm8 schedule` — Argumente, Auflösen, Lesen von Disk,
/// Änderungen nur über den Socket.
final class ScheduleCLITests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("schedcli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func task(_ name: String, id: String = UUID().uuidString) -> ScheduledTask {
        ScheduledTask(id: UUID(uuidString: id)!, name: name, prompt: "Hallo", directory: "/tmp", account: "main",
                      schedule: ScheduledTaskSchedule(kind: .weekdays, times: [ScheduledTaskClockTime(hour: 7, minute: 0)!]),
                      createdAt: ScheduledTaskCalendarTests.date("2026-11-16 12:00"))
    }

    // MARK: Argumente

    func testParseAdd() throws {
        let parsed = try ScheduleCLIArguments.parse([
            "add", "--name", "Abhängigkeiten prüfen", "--dir", "/tmp", "--account", "Zweitkonto",
            "--schedule", "stündlich :00", "--prompt", "Prüfe.", "--allow", "Bash(whisperm8 tickets *)",
            "--allow", "WebSearch", "--access", "read-only", "--no-catch-up",
        ])
        guard case .add(let options) = parsed else { return XCTFail("\(parsed)") }
        XCTAssertEqual(options.draft.name, "Abhängigkeiten prüfen")
        XCTAssertEqual(options.draft.schedule, ScheduledTaskSchedule(kind: .hourly, minute: 0))
        XCTAssertEqual(options.draft.extraTools, ["Bash(whisperm8 tickets *)", "WebSearch"])
        XCTAssertEqual(options.draft.access, .readOnly)
        XCTAssertEqual(options.draft.catchUp, false)
    }

    func testParseAddNamesWhatIsMissing() {
        XCTAssertThrowsError(try ScheduleCLIArguments.parse(["add", "--name", "x"])) { error in
            let message = (error as? ScheduleCLIArguments.ParseError)?.message ?? ""
            XCTAssertTrue(message.contains("--dir") && message.contains("--schedule") && message.contains("--account"), message)
        }
    }

    func testParseErrors() {
        for bad in [["run"], ["run", "a", "b"], ["edit"], ["add", "--bogus"], ["list", "extra"],
                    ["edit", "x", "--paused"], ["edit", "x", "--allow", "Read", "--clear-allow"],
                    ["add", "--schedule", "monatlich 07:00"], ["frobnicate"]] {
            XCTAssertThrowsError(try ScheduleCLIArguments.parse(bad), "\(bad)")
        }
        XCTAssertEqual(try ScheduleCLIArguments.parse([]), .help)
        XCTAssertEqual(try ScheduleCLIArguments.parse(["list", "--json"]), .list(json: true))
        XCTAssertEqual(try ScheduleCLIArguments.parse(["pause", "PM"]), .pause("PM"))
    }

    func testResolve() {
        let a = task("PM-Tagesbericht", id: "ABCD1234-0000-0000-0000-000000000001")
        let b = task("Abhängigkeiten prüfen", id: "ABCD9999-0000-0000-0000-000000000002")
        XCTAssertEqual(ScheduleCLIArguments.resolve("pm-tagesbericht", in: [a, b]), .found(a))
        XCTAssertEqual(ScheduleCLIArguments.resolve("abcd1", in: [a, b]), .found(a))
        XCTAssertEqual(ScheduleCLIArguments.resolve("abcd", in: [a, b]), .ambiguous([a, b]))
        XCTAssertEqual(ScheduleCLIArguments.resolve("abc", in: [a, b]), .none, "ID-Anfang erst ab 4 Zeichen")
    }

    // MARK: Ausführen

    func testListReadsFromDiskWithoutSocket() throws {
        let store = ScheduledTaskStore(root: root)
        let pm = task("PM-Tagesbericht")
        try store.save(ScheduledTasksFile(tasks: [pm]))
        let output = ScheduleCLICommand.execute(
            .list(json: false), store: store, now: ScheduledTaskCalendarTests.date("2026-11-17 08:00"),
            calendar: ScheduledTaskCalendarTests.calendar, enabled: false,
            send: { _, _ in XCTFail("list darf nichts senden"); return .ok(nil) })
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertTrue(output.stdout.contains("PM-Tagesbericht"))
        XCTAssertTrue(output.stdout.contains("werktags 07:00"))
        XCTAssertTrue(output.stdout.contains("Mi 18.11., 07:00"), output.stdout)
        XCTAssertTrue(output.stdout.contains("noch kein Lauf"))
        XCTAssertTrue(output.stderr.contains("aus"), "Hinweis, wenn der Labs-Schalter aus ist")
    }

    func testListShowsTheWorkingRunNotTheSkipAfterIt() throws {
        let store = ScheduledTaskStore(root: root)
        let pm = task("PM-Tagesbericht")
        try store.save(ScheduledTasksFile(tasks: [pm]))
        let started = ScheduledTaskCalendarTests.date("2026-11-17 07:00")
        let working = ScheduledTaskRunRecord(
            runID: ScheduledTaskRunRecord.makeRunID(now: started), taskID: pm.id, taskName: pm.name,
            sessionID: UUID(), account: "main", directory: "/tmp", trigger: .schedule, slot: started,
            createdAt: started, pid: 4242, processStartedAt: started)
        let skipAt = ScheduledTaskCalendarTests.date("2026-11-17 08:00")
        let skip = ScheduledTaskRunRecord(
            runID: ScheduledTaskRunRecord.makeRunID(now: skipAt), taskID: pm.id, taskName: pm.name, sessionID: nil,
            account: "main", directory: "/tmp", trigger: .schedule, slot: skipAt, createdAt: skipAt,
            notStarted: .stillRunning, message: "übersprungen")
        for record in [working, skip] {
            try store.writeRecord(record, in: store.runsDirectory(for: pm.id).appendingPathComponent(record.runID))
        }
        let context = ScheduleCLIFormatter.Context(store: store, now: skipAt, calendar: ScheduledTaskCalendarTests.calendar,
                                                   isProcessAlive: { pid, _ in pid == 4242 })
        XCTAssertEqual(context.latestRun(pm)?.outcome, .running)
        let ended = ScheduleCLIFormatter.Context(store: store, now: skipAt, calendar: ScheduledTaskCalendarTests.calendar,
                                                 isProcessAlive: { _, _ in false })
        XCTAssertEqual(ended.latestRun(pm)?.files.record.notStarted, .stillRunning, "Ohne laufenden Lauf: jüngster Eintrag")
    }

    func testAddSendsDraftAsJSONTextKeepingSmallNumbers() throws {
        let store = ScheduledTaskStore(root: root)
        var sent: (String, [String: Any])?
        let parsed = try ScheduleCLIArguments.parse([
            "add", "--name", "Stündlich", "--dir", root.path, "--account", "main",
            "--schedule", "stündlich :00", "--prompt", "Hallo",
        ])
        let output = ScheduleCLICommand.execute(
            parsed, store: store, now: Date(), calendar: .current, enabled: true,
            send: { method, params in
                sent = (method, params)
                return .ok(.object(["name": "Stündlich", "shortID": "abcd1234", "schedule": "stündlich :00"]))
            })
        XCTAssertEqual(output.exitCode, 0, output.stderr)
        XCTAssertEqual(sent?.0, "schedule.add")
        let text = try XCTUnwrap(sent?.1["draftJSON"] as? String)
        let draft = try AgentControlRequestHandler.decodeDraft(text)
        XCTAssertEqual(draft.schedule?.minute, 0)
        XCTAssertEqual(draft.directory, root.standardizedFileURL.path)
    }

    func testRunReportsNotStartedAsConflict() throws {
        let store = ScheduledTaskStore(root: root)
        let pm = task("PM-Tagesbericht")
        try store.save(ScheduledTasksFile(tasks: [pm]))
        let output = ScheduleCLICommand.execute(
            .run("PM-Tagesbericht"), store: store, now: Date(), calendar: .current, enabled: true,
            send: { method, params in
                XCTAssertEqual(method, "schedule.run")
                XCTAssertEqual(params["id"] as? String, pm.id.uuidString)
                return .ok(.object(["started": false, "message": "Login von main abgelaufen."]))
            })
        XCTAssertEqual(output.exitCode, ChatsCLIExit.conflict)
        XCTAssertTrue(output.stderr.contains("Login von main abgelaufen."))
    }

    func testUnknownTaskIsNotFound() throws {
        let output = ScheduleCLICommand.execute(
            .pause("gibt-es-nicht"), store: ScheduledTaskStore(root: root), now: Date(), calendar: .current,
            enabled: true, send: { _, _ in XCTFail("nichts senden"); return .ok(nil) })
        XCTAssertEqual(output.exitCode, ChatsCLIExit.notFound)
    }

    func testCommandIsRecognized() {
        XCTAssertTrue(CLIModeDetector.recognizedCommands.contains("schedule"))
        XCTAssertEqual(AgentControlRequestHandler.featureRoute(for: "schedule.run"), .schedule)
        XCTAssertEqual(ChatsControlProtocol.handlerTimeoutSeconds(for: "schedule.run"), 30)
    }

    // MARK: Socket-Seite

    func testHandlerAnswersDisabledWhenSwitchIsOff() async throws {
        let store = ScheduledTaskStore(root: root)
        var env = ScheduledTaskScheduler.Environment.live
        env.store = store
        env.isEnabled = { false }
        let scheduler = ScheduledTaskScheduler(environment: env)
        let request = ChatsControlRequest(actor: ChatsControlActor(), method: "schedule.run",
                                          params: .object(["id": UUID().uuidString]))
        let response = await AgentControlRequestHandler.scheduleResponse(request, scheduler: scheduler)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, ChatsControlErrorCode.unsupported.rawValue)
    }

    func testScheduledTasksPageLivesInLabs() {
        XCTAssertEqual(SettingsNavigation.launchClass(of: .scheduledTasks), .labs)
        XCTAssertTrue(SettingsNavigation.agentPages.contains(.scheduledTasks))
        XCTAssertFalse(AppPreferences(defaults: UserDefaults(suiteName: "schedcli-\(UUID().uuidString)")!).isScheduledTasksEnabled,
                       "Ab Werk aus")
    }
}
