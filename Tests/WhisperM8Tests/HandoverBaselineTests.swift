import XCTest
@testable import WhisperM8

/// Kennlinien vor dem Umbau „Neustart ohne Chatverlust“
/// (`docs/plans/neustart-ohne-chatverlust.md`, Abschnitt „Tests vor dem Umbau“).
/// Sie halten das HEUTIGE Verhalten fest. Ist der Labs-Schalter aus, muss es so
/// bleiben; wer hier etwas ändert, ändert das Verhalten für alle.
@MainActor
final class HandoverBaselineTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("handover-baseline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Beenden der App

    /// Ein Skript, das jedes SIGINT (Ctrl+C im PTY) in `log` vermerkt und
    /// `ready` anlegt, sobald die Falle steht.
    private func writeInterruptRecorder(named name: String) throws -> (log: URL, ready: URL) {
        let log = tempDir.appendingPathComponent("\(name).log")
        let ready = tempDir.appendingPathComponent("\(name).ready")
        let script = """
        trap 'echo INT >> "\(log.path)"' INT
        touch "\(ready.path)"
        while :; do sleep 0.05; done
        """
        try script.write(to: tempDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        return (log, ready)
    }

    private func waitFor(_ url: URL, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func interruptCount(_ log: URL) -> Int {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            .split(separator: "\n").count
    }

    func testAppQuitSendsCtrlCToChatsButNotToAttachedBackgroundTabs() throws {
        let chat = try writeInterruptRecorder(named: "chat")
        // `sh attach` führt das Skript `attach` im Arbeitsordner aus. Für die
        // Registry ist das ein Attach-Client (`arguments.first == "attach"`).
        let attach = try writeInterruptRecorder(named: "attach")
        let spy = SleepSpy()
        let registry = AgentTerminalRegistry(sleep: { spy($0) }, termination: .inert)
        let chatID = UUID(), attachID = UUID()
        registry.startController(
            sessionID: chatID,
            command: AgentLaunchCommand(executablePath: "/bin/sh", arguments: ["chat"],
                                        workingDirectory: tempDir.path, keyboardProfile: .claudeCodeChat),
            onLaunched: {}, onTerminated: { _ in })
        registry.startController(
            sessionID: attachID,
            command: AgentLaunchCommand(executablePath: "/bin/sh", arguments: ["attach"],
                                        workingDirectory: tempDir.path, keyboardProfile: .claudeCodeChat),
            onLaunched: {}, onTerminated: { _ in })
        defer { _ = registry.terminateAll() }
        XCTAssertTrue(registry.controller(for: attachID)?.command.isClaudeAttach == true)
        waitFor(chat.ready)
        waitFor(attach.ready)

        registry.captureAllSnapshotsForAppQuit()
        // Signale kommen asynchron an; kurz Zeit geben.
        let deadline = Date().addingTimeInterval(2)
        while interruptCount(chat.log) == 0, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertGreaterThanOrEqual(interruptCount(chat.log), 1, "Chat bekommt Ctrl+C beim Beenden")
        XCTAssertEqual(interruptCount(attach.log), 0, "angedockter Hintergrund-Tab bekommt kein Ctrl+C")
        XCTAssertEqual(spy.calls, [80_000, 180_000], "eine gemeinsame Wartezeit für alle Chats")
    }

    func testAppQuitWithOnlyAttachedTabsDoesNotWait() throws {
        _ = try writeInterruptRecorder(named: "attach")
        let spy = SleepSpy()
        let registry = AgentTerminalRegistry(sleep: { spy($0) }, termination: .inert)
        registry.startController(
            sessionID: UUID(),
            command: AgentLaunchCommand(executablePath: "/bin/sh", arguments: ["attach"],
                                        workingDirectory: tempDir.path, keyboardProfile: .claudeCodeChat),
            onLaunched: {}, onTerminated: { _ in })
        defer { _ = registry.terminateAll() }

        registry.captureAllSnapshotsForAppQuit()

        XCTAssertTrue(spy.calls.isEmpty)
    }

    // MARK: Hook-Bridge

    func testPreparingALaunchEmptiesTheEventFile() throws {
        let paths = ClaudeHookPaths(rootDirectory: tempDir)
        let bridge = ClaudeHookBridge(paths: paths)
        let id = UUID()
        let eventURL = paths.eventFileURL(localSessionID: id)
        try FileManager.default.createDirectory(at: paths.eventsDirectory, withIntermediateDirectories: true)
        try "{\"hook_event_name\":\"Stop\",\"session_id\":\"s\"}\n".write(to: eventURL, atomically: true, encoding: .utf8)

        XCTAssertNotNil(bridge.prepareSettingsFile(localSessionID: id))

        let size = try FileManager.default.attributesOfItem(atPath: eventURL.path)[.size] as? Int
        XCTAssertEqual(size, 0, "heute beginnt jeder Start mit einer leeren Event-Datei")
    }

    func testResettingTheCursorReadsTheEventFileFromTheStartAgain() throws {
        // `startTracking` setzt den Cursor zurück; ohne vorheriges prepare
        // würden damit alle alten Ereignisse ein zweites Mal geliefert.
        let url = tempDir.appendingPathComponent("events.jsonl")
        try """
        {"hook_event_name":"SessionStart","session_id":"s"}
        {"hook_event_name":"Stop","session_id":"s"}

        """.write(to: url, atomically: true, encoding: .utf8)
        let store = ClaudeHookEventStore()
        XCTAssertEqual(store.readNewEvents(from: url).count, 2)
        XCTAssertEqual(store.readNewEvents(from: url).count, 0)

        store.resetCursor(for: url)

        XCTAssertEqual(store.readNewEvents(from: url).count, 2)
    }
}

/// `make kill` und `make dev` beenden jeden Prozess, dessen Programm auf
/// `/WhisperM8` endet, außer dem Supervisor für Codex-Jobs. Neue abgekoppelte
/// Modi (Aufbewahrer, Router-Dienst) müssen hier ausgenommen werden.
final class MakefileProcessGuardTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testKillTargetSparesTheDetachedSupervisor() throws {
        let makefile = try String(contentsOf: Self.root.appendingPathComponent("Makefile"), encoding: .utf8)
        let line = try XCTUnwrap(makefile.split(separator: "\n").first { $0.hasPrefix("GUI_PIDS") })
        XCTAssertTrue(line.contains("agent-supervise"), "GUI_PIDS muss den Supervisor ausnehmen: \(line)")
        XCTAssertTrue(makefile.contains("kill: \n") || makefile.contains("kill:\n"))
        XCTAssertTrue(makefile.contains("$(GUI_PIDS)"), "kill nutzt GUI_PIDS")
    }
}
