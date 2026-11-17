import XCTest
@testable import WhisperM8

/// WM8-110 Paket 1: Planer mit Attrappen statt `claude` — kein Lauf doppelt,
/// Login vorher geprüft, verpasste Termine eingetragen, Wiedererkennen.
final class ScheduledTaskSchedulerTests: XCTestCase {
    /// Veränderlicher Zustand der Attrappen.
    final class Fake: @unchecked Sendable {
        var now: Date
        var enabled = true
        var accounts: Set<String> = ["main", "Zweitkonto"]
        var auth: ScheduledTaskLauncher.AuthStatus? = .init(loggedIn: true, loginExpiresAt: nil)
        var alivePIDs: Set<Int32> = []
        var nextPID: Int32 = 4000
        var plans: [ScheduledTaskLauncher.SpawnPlan] = []
        var authCalls = 0
        var exitHandlers: [Int32: @Sendable () -> Void] = [:]

        init(now: Date) { self.now = now }
    }

    private var root: URL!
    private var projectDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sched-\(UUID().uuidString)", isDirectory: true)
        projectDir = root.appendingPathComponent("projekt", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func date(_ text: String) -> Date { ScheduledTaskCalendarTests.date(text) }

    private func makeScheduler(_ fake: Fake) -> (ScheduledTaskScheduler, ScheduledTaskStore) {
        let store = ScheduledTaskStore(root: root.appendingPathComponent("support", isDirectory: true))
        let env = ScheduledTaskScheduler.Environment(
            store: store,
            now: { fake.now },
            calendar: { ScheduledTaskCalendarTests.calendar },
            isEnabled: { fake.enabled },
            claudePath: { "/usr/local/bin/claude" },
            accountEnvironment: { account in
                guard fake.accounts.contains(account) else { return nil }
                return account == "main" ? [:] : ["CLAUDE_CONFIG_DIR": "/profiles/\(account)"]
            },
            baseEnvironment: {
                // Läuft die App selbst aus einem Chat (Test-Instanz), stehen dessen Kennungen hier.
                ["PATH": "/usr/bin:/bin", "WHISPERM8_SESSION_ID": "chat-1", "WHISPERM8_SESSION_TOKEN": "geheim"]
            },
            authStatus: { _, _, _ in
                fake.authCalls += 1
                return fake.auth
            },
            supportsNativeName: { true },
            directoryExists: { path in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            },
            spawn: { plan in
                fake.plans.append(plan)
                fake.nextPID += 1
                fake.alivePIDs.insert(fake.nextPID)
                return fake.nextPID
            },
            processStartTime: { _ in fake.now },
            isProcessAlive: { pid, _ in fake.alivePIDs.contains(pid) },
            watchExit: { pid, handler in fake.exitHandlers[pid] = handler }
        )
        return (ScheduledTaskScheduler(environment: env), store)
    }

    private func draft(_ name: String = "Abhängigkeiten prüfen", schedule: String = "täglich 07:00",
                       account: String = "Zweitkonto", catchUp: Bool? = nil) -> ScheduledTaskDraft {
        guard case .success(let parsed) = ScheduledTaskSchedule.parse(schedule) else {
            XCTFail("Zeitplan")
            return ScheduledTaskDraft()
        }
        return ScheduledTaskDraft(name: name, prompt: "Prüfe die Abhängigkeiten.", directory: projectDir.path,
                                  account: account, schedule: parsed, catchUp: catchUp)
    }

    // MARK: Termin startet genau einmal

    func testDueSlotStartsOnceWithExpectedArguments() async throws {
        let fake = Fake(now: date("2026-11-16 12:00"))
        let (scheduler, store) = makeScheduler(fake)
        await scheduler.start()
        let task = try await scheduler.add(draft())

        fake.now = date("2026-11-17 07:01")
        await scheduler.evaluate(reason: "test")
        await scheduler.evaluate(reason: "test")
        XCTAssertEqual(fake.plans.count, 1, "Zweiter Durchlauf darf nichts starten")

        let plan = try XCTUnwrap(fake.plans.first)
        XCTAssertEqual(plan.workingDirectory, projectDir.path)
        XCTAssertEqual(plan.environment["CLAUDE_CONFIG_DIR"], "/profiles/Zweitkonto")
        XCTAssertEqual(plan.environment["WHISPERM8_SCHEDULED_TASK_ID"], task.id.uuidString.lowercased())
        XCTAssertNotNil(plan.environment["WHISPERM8_SCHEDULED_RUN_ID"])
        XCTAssertNil(plan.environment["WHISPERM8_SESSION_ID"], "Ein Lauf erbt nie die Kennung eines Chats")
        XCTAssertNil(plan.environment["WHISPERM8_SESSION_TOKEN"])
        let args = plan.claudeArguments
        XCTAssertEqual(Array(args.prefix(2)), ["-p", "Prüfe die Abhängigkeiten."])
        XCTAssertTrue(args.contains("--session-id"))
        XCTAssertEqual(args[args.firstIndex(of: "--permission-mode")! + 1], "dontAsk")
        XCTAssertEqual(Array(args.suffix(6)), ["--allowedTools", "Read", "Glob", "Grep", "Edit(/**)", "Skill"])
        let deny = args.firstIndex(of: "--disallowedTools")!
        XCTAssertEqual(Array(args[(deny + 1)...(deny + 5)]), ["Bash", "Monitor", "WebFetch", "WebSearch", "mcp__*"],
                       "Bash, Web und MCP ab Werk gesperrt, auch gegen Freigaben aus settings.json")
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        let name = args[args.firstIndex(of: "--name")! + 1]
        XCTAssertTrue(name.hasPrefix("Abhängigkeiten prüfen · "), name)

        let runs = store.recentRuns(for: task.id, limit: 5)
        XCTAssertEqual(runs.count, 1)
        let record = try XCTUnwrap(runs.first?.record)
        XCTAssertEqual(record.trigger, .schedule)
        XCTAssertEqual(record.slot, date("2026-11-17 07:00"))
        XCTAssertNotNil(record.pid)
        XCTAssertEqual(record.sessionID?.uuidString.lowercased(), args[args.firstIndex(of: "--session-id")! + 1])
        XCTAssertEqual(try store.load().tasks.first?.lastSlot, date("2026-11-17 07:00"))
    }

    func testCatchUpAfterSleepIsMarked() async throws {
        let fake = Fake(now: date("2026-11-16 12:00"))
        let (scheduler, store) = makeScheduler(fake)
        await scheduler.start()
        let task = try await scheduler.add(draft())
        fake.now = date("2026-11-17 09:30")
        await scheduler.evaluate(reason: "wake")
        XCTAssertEqual(store.recentRuns(for: task.id, limit: 1).first?.record.trigger, .catchUp)
    }

    func testStillRunningPreviousRunSkipsTheSlot() async throws {
        let fake = Fake(now: date("2026-11-16 12:00"))
        let (scheduler, store) = makeScheduler(fake)
        await scheduler.start()
        let task = try await scheduler.add(draft(schedule: "stündlich :00"))
        fake.now = date("2026-11-16 13:00")
        await scheduler.evaluate(reason: "timer")
        XCTAssertEqual(fake.plans.count, 1)

        fake.now = date("2026-11-16 14:00") // voriger Lauf lebt noch
        await scheduler.evaluate(reason: "timer")
        XCTAssertEqual(fake.plans.count, 1, "Kein zweiter Lauf, solange der erste arbeitet")
        let latest = try XCTUnwrap(store.recentRuns(for: task.id, limit: 1).first)
        XCTAssertEqual(latest.record.notStarted, .stillRunning)
    }

    /// Prüfung 17.11.: Nach einem „übersprungen“ ist der jüngste Ordner ein
    /// Eintrag ohne Prozess. Der nächste Termin darf trotzdem nicht neben dem
    /// noch arbeitenden Lauf starten.
    func testTwoSlotsInARowWhileTheFirstRunLives() async throws {
        let fake = Fake(now: date("2026-11-16 09:30"))
        let (scheduler, store) = makeScheduler(fake)
        await scheduler.start()
        let task = try await scheduler.add(draft(schedule: "stündlich :00"))
        fake.now = date("2026-11-16 10:00")
        await scheduler.evaluate(reason: "timer")
        XCTAssertEqual(fake.plans.count, 1)

        for slot in ["11:00", "12:00", "13:00", "14:00"] {
            fake.now = date("2026-11-16 \(slot)")
            await scheduler.evaluate(reason: "timer")
            XCTAssertEqual(fake.plans.count, 1, "\(slot): Lauf von 10:00 arbeitet noch")
        }
        let skips = store.recentRuns(for: task.id, limit: 4).map(\.record.notStarted)
        XCTAssertEqual(skips, Array(repeating: .stillRunning, count: 4))
        XCTAssertEqual(store.latestStartedRun(for: task.id)?.record.slot, date("2026-11-16 10:00"))
        do {
            _ = try await scheduler.runNow(id: task.id)
            XCTFail("Handstart neben dem arbeitenden Lauf")
        } catch let error as ScheduledTaskScheduler.SchedulerError {
            guard case .conflict = error else { return XCTFail("\(error)") }
        }

        // Lauf endet: Der nächste Termin startet wieder.
        fake.alivePIDs.removeAll()
        fake.now = date("2026-11-16 15:00")
        await scheduler.evaluate(reason: "timer")
        XCTAssertEqual(fake.plans.count, 2)
    }

    func testMissedSlotIsRecordedWithoutStarting() async throws {
        let fake = Fake(now: date("2026-11-16 12:00"))
        let (scheduler, store) = makeScheduler(fake)
        await scheduler.start()
        let task = try await scheduler.add(draft())
        fake.now = date("2026-11-17 21:00")
        await scheduler.evaluate(reason: "launch")
        XCTAssertTrue(fake.plans.isEmpty)
        XCTAssertEqual(store.recentRuns(for: task.id, limit: 1).first?.record.notStarted, .missed)
        await scheduler.evaluate(reason: "launch")
        XCTAssertEqual(store.recentRuns(for: task.id, limit: 5).count, 1, "Verpasst wird nur einmal eingetragen")
    }

    func testExpiredLoginDoesNotStart() async throws {
        let fake = Fake(now: date("2026-11-16 12:00"))
        fake.auth = .init(loggedIn: true, loginExpiresAt: date("2026-11-17 06:00"))
        let (scheduler, store) = makeScheduler(fake)
        await scheduler.start()
        let task = try await scheduler.add(draft())
        fake.now = date("2026-11-17 07:00")
        await scheduler.evaluate(reason: "timer")
        XCTAssertTrue(fake.plans.isEmpty)
        let record = try XCTUnwrap(store.recentRuns(for: task.id, limit: 1).first?.record)
        XCTAssertEqual(record.notStarted, .loginExpired)
        XCTAssertNil(record.sessionID, "Kein Chat ohne Start")
        XCTAssertTrue(record.message?.contains("Zweitkonto") ?? false)
    }

    func testLoggedOutAccountDoesNotStart() async throws {
        let fake = Fake(now: date("2026-11-16 12:00"))
        fake.auth = .init(loggedIn: false, loginExpiresAt: nil)
        let (scheduler, _) = makeScheduler(fake)
        await scheduler.start()
        let task = try await scheduler.add(draft())
        let record = try await scheduler.runNow(id: task.id)
        XCTAssertEqual(record.notStarted, .loginExpired)
        XCTAssertTrue(fake.plans.isEmpty)
    }

    func testRemovedAccountAndFolderDoNotStart() async throws {
        let fake = Fake(now: date("2026-11-16 12:00"))
        let (scheduler, _) = makeScheduler(fake)
        await scheduler.start()
        let task = try await scheduler.add(draft())
        fake.accounts.remove("Zweitkonto")
        let noAccount = try await scheduler.runNow(id: task.id)
        XCTAssertEqual(noAccount.notStarted, .accountMissing)
        try FileManager.default.removeItem(at: projectDir)
        fake.accounts.insert("Zweitkonto")
        let noFolder = try await scheduler.runNow(id: task.id)
        XCTAssertEqual(noFolder.notStarted, .folderMissing)
        XCTAssertEqual(fake.authCalls, 0, "Ohne Ordner und Konto keine Login-Prüfung")
    }

    // MARK: Handstart

    func testRunNowRefusesWhileARunWorks() async throws {
        let fake = Fake(now: date("2026-11-16 12:00"))
        let (scheduler, store) = makeScheduler(fake)
        await scheduler.start()
        let task = try await scheduler.add(draft())
        let first = try await scheduler.runNow(id: task.id)
        XCTAssertEqual(first.trigger, .manual)
        do {
            _ = try await scheduler.runNow(id: task.id)
            XCTFail("Zweiter Handstart darf nicht durchgehen")
        } catch let error as ScheduledTaskScheduler.SchedulerError {
            guard case .conflict = error else { return XCTFail("\(error)") }
        }
        // Nach dem Ende (Exit-Datei vom Lauf) geht es wieder.
        let pid = try XCTUnwrap(first.pid)
        fake.alivePIDs.remove(pid)
        let dir = try XCTUnwrap(store.recentRuns(for: task.id, limit: 1).first?.directory)
        try "0 1763362800\n".write(to: dir.appendingPathComponent("exit"), atomically: true, encoding: .utf8)
        _ = try await scheduler.runNow(id: task.id)
        XCTAssertEqual(fake.plans.count, 2)
        XCTAssertNil(try store.load().tasks.first?.lastSlot, "Handstart berührt den Zeitplan nicht")
    }

    // MARK: Ändern

    func testAddValidates() async throws {
        let fake = Fake(now: date("2026-11-16 12:00"))
        let (scheduler, _) = makeScheduler(fake)
        await scheduler.start()
        _ = try await scheduler.add(draft())
        var cases: [ScheduledTaskDraft] = []
        cases.append(draft()) // gleicher Name
        var dash = draft("Zweite"); dash.prompt = "--help"; cases.append(dash)
        var noDir = draft("Dritte"); noDir.directory = "/gibt/es/nicht"; cases.append(noDir)
        cases.append(draft("Vierte", account: "Unbekannt"))
        var custom = draft("Fünfte"); custom.access = .custom; cases.append(custom)
        for bad in cases {
            do {
                _ = try await scheduler.add(bad)
                XCTFail("\(bad) hätte abgelehnt werden müssen")
            } catch let error as ScheduledTaskScheduler.SchedulerError {
                guard case .invalid = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testEditedScheduleDoesNotFireForAPastSlot() async throws {
        let fake = Fake(now: date("2026-11-16 12:00"))
        let (scheduler, _) = makeScheduler(fake)
        await scheduler.start()
        let task = try await scheduler.add(draft(schedule: "täglich 20:00"))
        fake.now = date("2026-11-17 07:30")
        var change = ScheduledTaskDraft()
        change.schedule = ScheduledTaskSchedule(kind: .daily, times: [ScheduledTaskClockTime(hour: 7, minute: 0)!])
        _ = try await scheduler.edit(id: task.id, draft: change)
        await scheduler.evaluate(reason: "cli")
        XCTAssertTrue(fake.plans.isEmpty, "07:00 war schon vorbei, als der Zeitplan geändert wurde")
    }

    func testResumeDoesNotCatchUpThePause() async throws {
        let fake = Fake(now: date("2026-11-16 12:00"))
        let (scheduler, _) = makeScheduler(fake)
        await scheduler.start()
        let task = try await scheduler.add(draft())
        _ = try await scheduler.setPaused(id: task.id, paused: true)
        fake.now = date("2026-11-17 07:01")
        await scheduler.evaluate(reason: "timer")
        XCTAssertTrue(fake.plans.isEmpty)
        fake.now = date("2026-11-17 07:03")
        _ = try await scheduler.setPaused(id: task.id, paused: false)
        await scheduler.evaluate(reason: "cli")
        XCTAssertTrue(fake.plans.isEmpty, "Termin während der Pause läuft nach dem Fortsetzen nicht")
        fake.now = date("2026-11-18 07:00")
        await scheduler.evaluate(reason: "timer")
        XCTAssertEqual(fake.plans.count, 1)
    }

    func testRemoveDeletesTaskAndFinishedRuns() async throws {
        let fake = Fake(now: date("2026-11-16 12:00"))
        let (scheduler, store) = makeScheduler(fake)
        await scheduler.start()
        let task = try await scheduler.add(draft())
        fake.accounts.remove("Zweitkonto")
        _ = try await scheduler.runNow(id: task.id) // nicht gestartet, aber Ordner da
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.runsDirectory(for: task.id).path))
        _ = try await scheduler.remove(id: task.id)
        XCTAssertTrue(try store.load().tasks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.runsDirectory(for: task.id).path))
    }

    func testDisabledRefusesChangesAndDoesNotRun() async throws {
        let fake = Fake(now: date("2026-11-16 12:00"))
        let (scheduler, _) = makeScheduler(fake)
        await scheduler.start()
        let task = try await scheduler.add(draft())
        fake.enabled = false
        fake.now = date("2026-11-17 07:00")
        let next = await scheduler.evaluate(reason: "timer")
        XCTAssertNil(next)
        XCTAssertTrue(fake.plans.isEmpty)
        do {
            _ = try await scheduler.runNow(id: task.id)
            XCTFail("Aus heißt aus")
        } catch let error as ScheduledTaskScheduler.SchedulerError {
            XCTAssertEqual(error, .disabled)
        }
    }

    // MARK: Eine Instanz, Wiedererkennen

    func testOnlyOneSchedulerHoldsTheLock() async throws {
        let fake = Fake(now: date("2026-11-16 12:00"))
        let (first, _) = makeScheduler(fake)
        let (second, _) = makeScheduler(fake)
        let firstStarted = await first.start()
        let secondStarted = await second.start()
        XCTAssertTrue(firstStarted)
        XCTAssertFalse(secondStarted)
        do {
            _ = try await second.add(draft())
            XCTFail("Zweite Instanz darf nicht schreiben")
        } catch let error as ScheduledTaskScheduler.SchedulerError {
            XCTAssertEqual(error, .notLeader)
        }
    }

    func testRestartedSchedulerRecognizesARunningRun() async throws {
        let fake = Fake(now: date("2026-11-16 12:00"))
        var pid: Int32 = 0
        var taskID = UUID()
        do {
            let (before, _) = makeScheduler(fake)
            await before.start()
            let task = try await before.add(draft(schedule: "stündlich :00"))
            taskID = task.id
            let record = try await before.runNow(id: task.id)
            pid = try XCTUnwrap(record.pid)
        }
        fake.exitHandlers.removeAll()

        // „App-Neustart“: die alte Instanz ist weg, der Lauf lebt weiter.
        let (after, store) = makeScheduler(fake)
        let started = await after.start()
        XCTAssertTrue(started, "Sperre der alten Instanz ist frei")
        XCTAssertNotNil(fake.exitHandlers[pid], "Laufender Lauf wird nach dem Start beobachtet")
        fake.now = date("2026-11-16 13:00")
        await after.evaluate(reason: "timer")
        XCTAssertEqual(fake.plans.count, 1, "Lauf aus der Zeit vor dem Neustart arbeitet noch: kein zweiter")
        XCTAssertEqual(store.recentRuns(for: taskID, limit: 1).first?.record.notStarted, .stillRunning)
    }

    func testRestartRecognizesARunBehindSeveralSkips() async throws {
        let fake = Fake(now: date("2026-11-16 09:30"))
        var pid: Int32 = 0
        var taskID = UUID()
        do {
            let (before, _) = makeScheduler(fake)
            await before.start()
            let task = try await before.add(draft(schedule: "stündlich :00"))
            taskID = task.id
            fake.now = date("2026-11-16 10:00")
            await before.evaluate(reason: "timer")
            XCTAssertEqual(fake.plans.count, 1)
            pid = fake.nextPID
            for slot in ["11:00", "12:00", "13:00"] {
                fake.now = date("2026-11-16 \(slot)")
                await before.evaluate(reason: "timer")
            }
        }
        fake.exitHandlers.removeAll()

        let (after, store) = makeScheduler(fake)
        _ = await after.start()
        XCTAssertNotNil(fake.exitHandlers[pid], "Lauf hinter drei „übersprungen“ wird wiedererkannt")
        fake.now = date("2026-11-16 14:00")
        await after.evaluate(reason: "timer")
        XCTAssertEqual(fake.plans.count, 1)
        XCTAssertEqual(store.recentRuns(for: taskID, limit: 1).first?.record.notStarted, .stillRunning)
    }

    func testCustomAllowOpensOnlyTheNamedFamily() {
        let bash = ScheduledTaskPermissions(access: .readOnly, extraTools: ["Bash(whisperm8 tickets *)"])
        let protected = ScheduledTaskPermissions.protectedPaths + ScheduledTaskPermissions.gatedTools
        XCTAssertEqual(bash.disallowedTools, ["WebFetch", "WebSearch", "mcp__*"] + protected, "Bash öffnet auch Monitor")
        XCTAssertFalse(bash.allowsMCP)

        let mcp = ScheduledTaskPermissions(access: .projectWrite, extraTools: [" mcp__linear__get_issue", "WebSearch"])
        XCTAssertEqual(mcp.disallowedTools, ["Bash", "Monitor", "WebFetch"] + protected)
        XCTAssertTrue(mcp.allowsMCP)
        let args = ScheduledTaskLauncher.claudeArguments(prompt: "x", sessionID: UUID(), name: nil, permissions: mcp)
        XCTAssertFalse(args.contains("--strict-mcp-config"), "MCP freigegeben: Server des Kontos laden")
        XCTAssertFalse(args.contains("mcp__*"))

        let bashPrefix = ScheduledTaskPermissions(access: .custom, extraTools: ["BashOutput"])
        XCTAssertEqual(bashPrefix.disallowedTools.first, "Bash", "Nur Bash oder Bash(…) öffnet Bash")

        let monitor = ScheduledTaskPermissions(access: .projectWrite, extraTools: ["Monitor"])
        XCTAssertEqual(monitor.disallowedTools, ["Bash", "WebFetch", "WebSearch", "mcp__*"] + protected,
                       "--allow Monitor öffnet nur Monitor")
    }

    /// Probelauf 17.11.: Ein Lauf hatte SendMessage, ListAgents, RemoteTrigger,
    /// CronCreate/CronDelete und PushNotification — Wege nach außen an der
    /// Bash-Sperre vorbei. Gesperrt in jeder Stufe, offen nur einzeln per --allow.
    func testOutwardToolsAreBlockedUnlessAllowed() {
        let outward = ["SendMessage", "ListAgents", "RemoteTrigger", "CronCreate", "CronDelete", "PushNotification",
                       "DesignSync", "EnterWorktree", "ExitWorktree"]
        for permissions in [ScheduledTaskPermissions(access: .projectWrite), ScheduledTaskPermissions(access: .readOnly),
                            ScheduledTaskPermissions(access: .custom, extraTools: ["Read", "Bash", "mcp__x__y"])] {
            let args = ScheduledTaskLauncher.claudeArguments(prompt: "x", sessionID: UUID(), name: nil,
                                                             permissions: permissions)
            let deny = args.firstIndex(of: "--disallowedTools")!
            let denied = Array(args[(deny + 1)...].prefix(while: { !$0.hasPrefix("--") }))
            for tool in outward {
                XCTAssertTrue(denied.contains(tool), "\(tool) fehlt bei \(permissions.access)")
            }
            XCTAssertFalse(denied.contains("Agent"), "Agent bleibt: Subagents erben die Sperren")
        }
        let open = ScheduledTaskPermissions(access: .readOnly, extraTools: ["SendMessage", "CronCreate(*)"])
        XCTAssertFalse(open.disallowedTools.contains("SendMessage"))
        XCTAssertFalse(open.disallowedTools.contains("CronCreate"))
        XCTAssertTrue(open.disallowedTools.contains("CronDelete"), "Nur das genannte Werkzeug öffnet")
        XCTAssertTrue(open.disallowedTools.contains("ListAgents"))
        XCTAssertTrue(open.disallowedTools.contains("EnterWorktree"))
    }

    /// Prüfung 17.11.: Ein Lauf darf nichts schreiben, was der nächste Lauf
    /// ausführt (Hooks, settings.local.json, Git-Hooks, MCP-Server) — auch
    /// nicht, wenn eine eigene Liste oder das Konto Edit breiter freigibt.
    func testRunsCannotWriteWhatTheNextRunExecutes() {
        for permissions in [ScheduledTaskPermissions(access: .projectWrite),
                            ScheduledTaskPermissions(access: .custom, extraTools: ["Edit", "Write", "Bash"])] {
            let args = ScheduledTaskLauncher.claudeArguments(prompt: "x", sessionID: UUID(), name: nil,
                                                             permissions: permissions)
            let deny = args.firstIndex(of: "--disallowedTools")!
            let denied = args[(deny + 1)...].prefix(while: { !$0.hasPrefix("--") })
            for path in ["Edit(/.claude/**)", "Edit(/.git/**)", "Edit(/.mcp.json)"] {
                XCTAssertTrue(denied.contains(path), "\(path) fehlt bei \(permissions.access)")
            }
        }
    }

    func testLatestStartedRunLooksOnlyAtTheNewestFolders() throws {
        let store = ScheduledTaskStore(root: root.appendingPathComponent("support", isDirectory: true))
        let taskID = UUID()
        func write(_ at: Date, notStarted: ScheduledTaskRunRecord.NotStarted?) throws {
            let record = ScheduledTaskRunRecord(
                runID: ScheduledTaskRunRecord.makeRunID(now: at), taskID: taskID, taskName: "Probe",
                sessionID: notStarted == nil ? UUID() : nil, account: "main", directory: "/tmp", trigger: .schedule,
                slot: at, createdAt: at, pid: notStarted == nil ? 4100 : nil, notStarted: notStarted)
            try store.writeRecord(record, in: store.runsDirectory(for: taskID).appendingPathComponent(record.runID))
        }
        let start = date("2026-11-10 08:00")
        try write(start, notStarted: nil)
        for hour in 1...3 { try write(start.addingTimeInterval(Double(hour) * 3600), notStarted: .loginExpired) }
        XCTAssertEqual(store.latestStartedRun(for: taskID)?.record.slot, start)
        XCTAssertNil(store.latestStartedRun(for: taskID, scanLimit: 3), "Nur die jüngsten Ordner, nicht alle")
    }

    func testAllowStartingWithDashIsRejected() async throws {
        let fake = Fake(now: date("2026-11-16 12:00"))
        let (scheduler, _) = makeScheduler(fake)
        await scheduler.start()
        var bad = draft()
        bad.extraTools = ["--dangerously-skip-permissions"]
        do {
            _ = try await scheduler.add(bad)
            XCTFail("Werkzeug mit „-“ wäre eine Option")
        } catch let error as ScheduledTaskScheduler.SchedulerError {
            guard case .invalid = error else { return XCTFail("\(error)") }
        }
    }
}
