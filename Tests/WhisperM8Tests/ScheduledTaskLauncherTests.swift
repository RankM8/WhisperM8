import XCTest
@testable import WhisperM8

/// WM8-110 Paket 1: losgelöster Start, Ergebnis-Auswertung, Login-Prüfung.
final class ScheduledTaskLauncherTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Echter Start mit Ersatz-claude

    /// Ein Shell-Skript statt `claude`: schreibt JSON nach stdout, die Liste
    /// offener Deskriptoren nach stderr, wartet kurz und endet mit Exit 0.
    private func fakeClaude(body: String) throws -> URL {
        let url = root.appendingPathComponent("fake-claude")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            usleep(20_000)
        }
        return false
    }

    func testDetachedRunWritesResultAndExitAndRunsInOwnSession() throws {
        let claude = try fakeClaude(body: """
        /bin/sleep 0.3
        printf '{"type":"result","subtype":"success","is_error":false,"result":"Fertig.\\\\nAlles geprüft.","permission_denials":[]}'
        /bin/ls /dev/fd 1>&2
        pwd 1>&2
        exit 0
        """)
        let runDir = root.appendingPathComponent("run", isDirectory: true)
        let workDir = root.appendingPathComponent("projekt", isDirectory: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        // Ein Deskriptor ohne close-on-exec: Der Lauf darf ihn nicht erben.
        // Hoch gelegt (F_DUPFD setzt kein close-on-exec), damit `ls` ihn nicht mit eigenen verwechselt.
        let opened = open(root.appendingPathComponent("geheim").path, O_RDWR | O_CREAT, 0o600)
        let leaked = fcntl(opened, F_DUPFD, 40)
        close(opened)
        XCTAssertGreaterThanOrEqual(leaked, 40)
        defer { close(leaked) }

        let plan = ScheduledTaskLauncher.SpawnPlan(
            claudePath: claude.path, claudeArguments: ["-p", "Hallo"],
            environment: ["PATH": "/usr/bin:/bin"], workingDirectory: workDir.path, runDirectory: runDir)
        let pid = try ScheduledTaskLauncher.spawnDetached(plan)
        XCTAssertGreaterThan(pid, 0)
        XCTAssertEqual(getsid(pid), pid, "Eigene Sitzung: überlebt das Ende der App")
        XCTAssertEqual(getpgid(pid), pid, "Eigene Prozessgruppe")

        let exitURL = runDir.appendingPathComponent("exit")
        XCTAssertTrue(waitForFile(exitURL))
        var status: Int32 = 0
        waitpid(pid, &status, 0)

        let exit = try XCTUnwrap(ScheduledTaskRunExit(parsing: String(contentsOf: exitURL, encoding: .utf8)))
        XCTAssertEqual(exit.code, 0)
        XCTAssertNotNil(exit.endedAt)
        let stderr = try String(contentsOf: runDir.appendingPathComponent("stderr.log"), encoding: .utf8)
        let fds = stderr.split(whereSeparator: \.isNewline).dropLast().compactMap { Int32($0) }
        XCTAssertFalse(fds.contains(leaked), "Deskriptor \(leaked) wurde vererbt: \(fds)")
        XCTAssertTrue(stderr.contains(workDir.lastPathComponent), "Startordner fehlt: \(stderr)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: exitURL.path + ".tmp"))

        let result = try Data(contentsOf: runDir.appendingPathComponent("result.json"))
        XCTAssertEqual(ScheduledTaskRunEvaluator.finished(exitCode: exit.code, result: result, stderrTail: nil),
                       .succeeded(summary: "Alles geprüft."))
    }

    func testFailingRunKeepsItsExitCode() throws {
        let claude = try fakeClaude(body: "echo 'Error: Invalid API key' 1>&2\nexit 3")
        let runDir = root.appendingPathComponent("run2", isDirectory: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let pid = try ScheduledTaskLauncher.spawnDetached(.init(
            claudePath: claude.path, claudeArguments: [], environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: root.path, runDirectory: runDir))
        XCTAssertTrue(waitForFile(runDir.appendingPathComponent("exit")))
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let store = ScheduledTaskStore(root: root)
        let record = ScheduledTaskRunRecord(runID: "r", taskID: UUID(), taskName: "Probe", sessionID: UUID(),
                                            account: "main", directory: root.path, trigger: .manual, slot: nil,
                                            createdAt: Date(), pid: pid)
        try store.writeRecord(record, in: runDir)
        let files = try XCTUnwrap(store.readRun(at: runDir))
        XCTAssertEqual(files.exit?.code, 3)
        XCTAssertEqual(ScheduledTaskRunEvaluator.outcome(of: files, isProcessAlive: { _, _ in false }),
                       .failed(message: "Error: Invalid API key"))
    }

    // MARK: Argumente

    func testClaudeArgumentsOrder() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let config = ScheduledTaskRunConfig(settingsFile: "/lauf/claude-config/settings.json",
                                            pluginDirectory: "/lauf/claude-config/plugins",
                                            contextFile: "/lauf/claude-config/context.md",
                                            mcpConfigFile: "/lauf/claude-config/mcp.json")
        let permissions = ScheduledTaskPermissions(access: .custom, extraTools: ["Read", "Skill", "Bash(echo:*)", "mcp__linear__get_issue"])
        let args = ScheduledTaskLauncher.claudeArguments(prompt: "/pm-analyse Modus: morgen", sessionID: id,
                                                         name: "Probe · 17.11.", permissions: permissions, config: config)
        let protected = ScheduledTaskPermissions.protectedPaths + ScheduledTaskPermissions.gatedTools
        XCTAssertEqual(args, ["-p", "/pm-analyse Modus: morgen", "--output-format", "json",
                              "--session-id", "11111111-2222-3333-4444-555555555555", "--name", "Probe · 17.11.",
                              "--setting-sources", "", "--settings", "/lauf/claude-config/settings.json",
                              "--plugin-dir", "/lauf/claude-config/plugins",
                              "--append-system-prompt-file", "/lauf/claude-config/context.md",
                              "--disallowedTools", "WebFetch", "WebSearch", "mcp__whisperm8__*"] + protected + [
                              "--strict-mcp-config", "--mcp-config", "/lauf/claude-config/mcp.json",
                              "--permission-mode", "dontAsk",
                              "--allowedTools", "Read", "Skill", "Bash(echo:*)", "mcp__linear__get_issue",
                              "Read(//lauf/claude-config/plugins/**)"])
        let bare = ScheduledTaskLauncher.claudeArguments(prompt: "x", sessionID: id, name: nil,
                                                         permissions: .init(), config: .probe)
        XCTAssertFalse(bare.contains("--name"))
        XCTAssertFalse(bare.contains("--plugin-dir"))
        XCTAssertFalse(bare.contains("--mcp-config"), "Ohne MCP-Freigabe kein Server")
        XCTAssertTrue(bare.contains("--strict-mcp-config"))
    }

    /// Paket 4: Ohne Einstellungsquellen gelten nur die Freigaben der Aufgabe.
    /// Das leere Argument nach `--setting-sources` ist Absicht.
    func testRunsLoadNoSettingsFiles() {
        let args = ScheduledTaskLauncher.claudeArguments(prompt: "x", sessionID: UUID(), name: nil,
                                                         permissions: .init(), config: .probe)
        let index = try? XCTUnwrap(args.firstIndex(of: "--setting-sources"))
        XCTAssertEqual(index.map { args[$0 + 1] }, "")
        XCTAssertEqual(args[args.firstIndex(of: "--settings")! + 1], ScheduledTaskRunConfig.probe.settingsFile)
    }

    func testWrapperRemovesRunConfigFolder() {
        XCTAssertTrue(ScheduledTaskLauncher.wrapperScript.contains("/\(ScheduledTaskRunConfigBuilder.folderName)\""))
        XCTAssertTrue(ScheduledTaskLauncher.wrapperScript.contains("/*/exit)"), "Nur bei einem absoluten Pfad auf exit")
    }

    func testDefaultPermissionsDenyBashWebAndMCP() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        for access in [ScheduledTaskPermissions.Access.projectWrite, .readOnly] {
            let args = ScheduledTaskLauncher.claudeArguments(prompt: "/pm-analyse", sessionID: id, name: nil,
                                                             permissions: ScheduledTaskPermissions(access: access),
                                                             config: .probe)
            let tail = Array(args.drop(while: { $0 != "--disallowedTools" }))
            XCTAssertEqual(Array(tail.prefix(21)), [
                "--disallowedTools", "Bash", "Monitor", "WebFetch", "WebSearch", "mcp__*",
                "Edit(/.claude/**)", "Edit(/.git/**)", "Edit(/.mcp.json)",
                "SendMessage", "ListAgents", "RemoteTrigger", "CronCreate", "CronDelete", "PushNotification",
                "DesignSync", "EnterWorktree", "ExitWorktree",
                "--strict-mcp-config", "--permission-mode", "dontAsk"], "\(access)")
            XCTAssertEqual(args.last, "Skill", "--allowedTools bleibt zuletzt")
        }
    }

    func testSessionNameUsesShortDate() {
        let name = ScheduledTaskLauncher.sessionName(
            taskName: "PM-Tagesbericht", date: ScheduledTaskCalendarTests.date("2026-11-17 07:00"),
            locale: Locale(identifier: "de_DE"), timeZone: ScheduledTaskCalendarTests.berlin)
        XCTAssertEqual(name, "PM-Tagesbericht · 17.11.")
    }

    // MARK: Login

    func testAuthStatusParsing() {
        let json = #"{"loggedIn": true, "loginExpiresAt": "2026-11-30T17:24:01.848Z", "subscriptionType": "max"}"#
        let status = ScheduledTaskLauncher.parseAuthStatus(stdout: json, exitCode: 0)
        XCTAssertEqual(status?.loggedIn, true)
        XCTAssertEqual(status?.loginExpiresAt, ScheduledTaskLauncher.parseISODate("2026-11-30T17:24:01.848Z"))
        XCTAssertNotNil(status?.loginExpiresAt)
        XCTAssertEqual(ScheduledTaskLauncher.parseAuthStatus(stdout: #"{"loggedIn": false}"#, exitCode: 1)?.loggedIn, false)
        XCTAssertNil(ScheduledTaskLauncher.parseAuthStatus(stdout: "unbekannt", exitCode: 0),
                     "Unbekanntes Format blockiert den Lauf nicht")
    }

    // MARK: Ergebnis

    func testResultWithDenialsIsSuccessWithNote() {
        let json = #"{"subtype":"success","is_error":false,"result":"Bericht geschrieben.","permission_denials":[{"tool_name":"Bash","tool_use_id":"x"},{"tool_name":"Bash"},{"tool_name":"WebFetch"}]}"#
        XCTAssertEqual(ScheduledTaskRunEvaluator.finished(exitCode: 0, result: Data(json.utf8), stderrTail: nil),
                       .succeededWithNotes(summary: "Bericht geschrieben.", deniedTools: ["Bash", "WebFetch"]))
    }

    func testErrorResultFails() {
        let json = #"{"subtype":"error_during_execution","is_error":true,"result":"Prompt is too long"}"#
        XCTAssertEqual(ScheduledTaskRunEvaluator.finished(exitCode: 1, result: Data(json.utf8), stderrTail: "x"),
                       .failed(message: "Prompt is too long"))
        XCTAssertEqual(ScheduledTaskRunEvaluator.finished(exitCode: 0, result: nil, stderrTail: nil),
                       .failed(message: "Kein Ergebnis vom Lauf (Exit 0, result.json leer)."))
    }

    func testRunningStartingAndAborted() {
        var record = ScheduledTaskRunRecord(runID: "r", taskID: UUID(), taskName: "Probe", sessionID: UUID(),
                                            account: "main", directory: "/tmp", trigger: .schedule, slot: nil,
                                            createdAt: ScheduledTaskCalendarTests.date("2026-11-17 07:00"))
        var files = ScheduledTaskRunFiles(directory: root, record: record, exit: nil, result: nil, stderrTail: nil)
        let now = ScheduledTaskCalendarTests.date("2026-11-17 07:01")
        XCTAssertEqual(ScheduledTaskRunEvaluator.outcome(of: files, now: now, isProcessAlive: { _, _ in true }), .starting)
        XCTAssertEqual(ScheduledTaskRunEvaluator.outcome(of: files, now: now.addingTimeInterval(600), isProcessAlive: { _, _ in true }),
                       .aborted, "Ohne PID nach der Startfrist: beim Starten gestorben")
        record.pid = 42
        files.record = record
        XCTAssertEqual(ScheduledTaskRunEvaluator.outcome(of: files, isProcessAlive: { pid, _ in pid == 42 }), .running)
        XCTAssertEqual(ScheduledTaskRunEvaluator.outcome(of: files, isProcessAlive: { _, _ in false }), .aborted)
    }

    func testOwnProcessIsAliveAndStartTimeGuardsAgainstReuse() {
        let me = getpid()
        let started = ProcessAncestry.startTime(for: me)
        XCTAssertTrue(ScheduledTaskRunEvaluator.isProcessAlive(pid: me, startedAt: started))
        XCTAssertFalse(ScheduledTaskRunEvaluator.isProcessAlive(pid: me, startedAt: started?.addingTimeInterval(-60)))
    }

    func testRunIDSortsByTime() {
        let early = ScheduledTaskRunRecord.makeRunID(now: ScheduledTaskCalendarTests.date("2026-11-17 07:00"), random: "aaaaaa")
        let late = ScheduledTaskRunRecord.makeRunID(now: ScheduledTaskCalendarTests.date("2026-11-17 22:30"), random: "000000")
        XCTAssertEqual(early, "20261117T060000Z-aaaaaa")
        XCTAssertLessThan(early, late)
    }

    // MARK: Ablage

    func testUnreadableFileIsNeverOverwritten() throws {
        let store = ScheduledTaskStore(root: root)
        try #"{"version": 9, "tasks": []}"#.write(to: store.fileURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.load())
        try "kaputt".write(to: store.fileURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.load())
        try FileManager.default.removeItem(at: store.fileURL)
        XCTAssertEqual(try store.load(), ScheduledTasksFile())
    }

    func testFileRoundTripAndPermissions() throws {
        let store = ScheduledTaskStore(root: root.appendingPathComponent("support"))
        let task = ScheduledTask(name: "Probe", prompt: "Hallo", directory: "/tmp", account: "main",
                                 schedule: ScheduledTaskSchedule(kind: .weekly, times: [ScheduledTaskClockTime(hour: 8, minute: 0)!], days: [1, 3]),
                                 permissions: .init(access: .readOnly, extraTools: ["WebSearch"]),
                                 createdAt: Date(timeIntervalSince1970: 1_763_000_000))
        try store.save(ScheduledTasksFile(tasks: [task]))
        XCTAssertEqual(try store.load().tasks, [task])
        let mode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
}

extension ScheduledTaskRunConfig {
    /// Lauf-Einstellungen ohne Skills, CLAUDE.md und MCP.
    static let probe = ScheduledTaskRunConfig(settingsFile: "/lauf/claude-config/settings.json")
}
