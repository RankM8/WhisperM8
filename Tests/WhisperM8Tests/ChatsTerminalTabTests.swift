import XCTest
@testable import WhisperM8

/// CLI-Paket für den Dauerlauf (Jarvis/Dex, 13.11.2026): Terminal-Tab per
/// `chats new --provider terminal [--command]`, `debug terminal --text`,
/// PID in `chats show --json`, ruhige Zeile bei altem Build, Router-Modus
/// in `debug state`.
final class ChatsTerminalTabTests: XCTestCase {
    // MARK: chats new

    func testParsesTerminalWithCommand() throws {
        let parsed = try ChatsNewArguments.parse(["--project", "/p", "--provider", "terminal",
                                                  "--command", "/bin/sh '/p/counter.sh'", "--title", "Zähler"]).get()
        XCTAssertEqual(parsed.provider, "terminal")
        XCTAssertEqual(parsed.command, "/bin/sh '/p/counter.sh'")
        XCTAssertEqual(parsed.controlParams["command"] as? String, "/bin/sh '/p/counter.sh'")
        XCTAssertEqual(parsed.controlParams["provider"] as? String, "terminal")
    }

    func testTerminalWithoutCommandIsALoginShell() throws {
        let parsed = try ChatsNewArguments.parse(["--project", "/p", "--provider", "terminal"]).get()
        XCTAssertNil(parsed.command)
        XCTAssertNil(parsed.controlParams["command"])
    }

    func testCommandOnlyWithTerminalAndNoPromptOrAccountForTerminal() {
        XCTAssertEqual(ChatsNewArguments.parse(["--project", "/p", "--command", "x"]), .failure(.commandRequiresTerminal))
        XCTAssertEqual(ChatsNewArguments.parse(["--project", "/p", "--provider", "codex", "--command", "x"]),
                       .failure(.commandRequiresTerminal))
        XCTAssertEqual(ChatsNewArguments.parse(["--project", "/p", "--provider", "terminal", "--prompt", "x"]),
                       .failure(.optionNotForTerminal("--prompt")))
        XCTAssertEqual(ChatsNewArguments.parse(["--project", "/p", "--provider", "terminal", "--account", "main"]),
                       .failure(.optionNotForTerminal("--account")))
        XCTAssertEqual(ChatsNewArguments.parse(["--project", "/p", "--provider", "shell"]), .failure(.invalidProvider("shell")))
    }

    /// Dex erkennt das Paket an der Hilfe.
    func testHelpNamesTerminalProviderAndDebugTerminal() {
        XCTAssertTrue(ChatsNewArguments.usage.contains("--provider claude|codex|terminal"))
        XCTAssertTrue(DebugCLICommand.help.components(separatedBy: "\n").contains { $0.hasPrefix("  terminal") })
    }

    /// Klare Meldung statt stillem Verlust, wenn der Tab noch nie angezeigt wurde.
    func testStartLineSaysWhetherTheTabRuns() {
        XCTAssertEqual(ChatsNewCommand.terminalStartLine(ref: "abcd1234", state: .running(pid: 4711)),
                       "Terminal-Tab läuft (PID 4711).")
        XCTAssertEqual(ChatsNewCommand.terminalStartLine(ref: "abcd1234", state: .running(pid: nil)), "Terminal-Tab läuft.")
        XCTAssertTrue(ChatsNewCommand.terminalStartLine(ref: "abcd1234", state: .alreadyEnded).contains("schon beendet"))
        let waiting = ChatsNewCommand.terminalStartLine(ref: "abcd1234", state: .notStarted)
        XCTAssertTrue(waiting.contains("läuft aber noch nicht"))
        XCTAssertTrue(waiting.contains("whisperm8 chats open abcd1234"))
    }

    /// Opus-Review: `/bin/sh -c` ersetzt sich oft durch den Befehl; ohne
    /// Kindprozess fragte das Schließen sonst nicht nach.
    func testFixedCommandTabAlwaysAsksBeforeEnding() {
        XCTAssertTrue(ProcessEndConfirmation.terminalNeedsConfirmation(isRunning: true, shellHasChildProcess: false,
                                                                      runsFixedCommand: true))
        XCTAssertFalse(ProcessEndConfirmation.terminalNeedsConfirmation(isRunning: false, shellHasChildProcess: false,
                                                                       runsFixedCommand: true))
        XCTAssertFalse(ProcessEndConfirmation.terminalNeedsConfirmation(isRunning: true, shellHasChildProcess: false),
                       "Login-Shell ohne Kind wie bisher")
    }

    /// Rundlauf über den Draht: sessions.live → ChatsLiveMerge-Parser.
    func testLiveEntryParsesPidAndHasStarted() {
        let entry = ChatsControlJSON(any: ["sessionID": UUID().uuidString, "isAttachedPTY": false, "hasStarted": true,
                                           "pid": AgentControlRequestHandler.livePID(nil)] as [String: Any])
        XCTAssertEqual(entry["hasStarted"]?.boolValue, true)
        XCTAssertNil(entry["pid"]?.intValue)
    }

    // MARK: Startkommando und Modell

    func testTerminalCommandRunsViaShellInTheProject() {
        let project = AgentProject(name: "p", path: "/tmp/p")
        let command = AgentCommandBuilder.terminalRunCommand("/bin/sh '/tmp/p/counter.sh'", project: project)
        XCTAssertEqual(command.executablePath, "/bin/sh")
        XCTAssertEqual(command.arguments, ["-c", "/bin/sh '/tmp/p/counter.sh'"])
        XCTAssertEqual(command.workingDirectory, "/tmp/p")
        XCTAssertEqual(command.keyboardProfile, .plainShell)
    }

    func testTerminalCommandSurvivesTheWorkspaceFileAndOldFilesDecode() throws {
        var session = AgentChatSession(provider: .claude, projectID: UUID(), title: "Zähler", kind: .terminal)
        session.terminalCommand = "echo hi"
        let data = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(AgentChatSession.self, from: data).terminalCommand, "echo hi")
        var plain = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        plain.removeValue(forKey: "terminalCommand")
        let old = try JSONSerialization.data(withJSONObject: plain)
        XCTAssertNil(try JSONDecoder().decode(AgentChatSession.self, from: old).terminalCommand)
    }

    func testStoreKeepsTheCommandOnlyForTerminalTabs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wm8-termtab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentSessionStore(fileURL: dir.appendingPathComponent("ws.json"),
                                      uiStateFileURL: dir.appendingPathComponent("ui.json"))
        let terminal = try store.createSession(provider: .claude, projectPath: dir.path, title: "T",
                                               kind: .terminal, terminalCommand: "echo hi")
        let chat = try store.createSession(provider: .claude, projectPath: dir.path, title: "C",
                                           terminalCommand: "echo hi")
        XCTAssertEqual(terminal.terminalCommand, "echo hi")
        XCTAssertNil(chat.terminalCommand, "nur Terminal-Tabs führen einen Befehl aus")
    }

    // MARK: Auflagen Vic (Gate, Verfall)

    /// `--command` nur mit dem Debug-Steuerkanal; ein Tab ohne Befehl bleibt frei.
    func testCommandNeedsDebugControl() {
        XCTAssertNotNil(AgentControlRequestHandler.terminalCommandRefusal(command: "echo hi", debugControlEnabled: false))
        XCTAssertTrue(AgentControlRequestHandler.terminalCommandRefusal(command: "echo hi", debugControlEnabled: false)?
            .contains("debugControlEnabled") == true)
        XCTAssertNil(AgentControlRequestHandler.terminalCommandRefusal(command: "echo hi", debugControlEnabled: true))
        XCTAssertNil(AgentControlRequestHandler.terminalCommandRefusal(command: nil, debugControlEnabled: false))
        XCTAssertNil(AgentControlRequestHandler.terminalCommandRefusal(command: "", debugControlEnabled: false))
        XCTAssertTrue(ChatsNewArguments.usage.contains("debugControlEnabled"))
    }

    /// Nie gestarteter Befehls-Tab aus einem früheren App-Lauf startet nicht
    /// mehr von selbst; ein frisch angelegter schon.
    func testNeverStartedCommandTabFromAnEarlierRunExpires() {
        let launch = Date(timeIntervalSince1970: 2_000_000)
        func tab(created: TimeInterval, started: Bool = false, command: String? = "echo hi",
                 kind: AgentSessionKind = .terminal) -> AgentChatSession {
            var session = AgentChatSession(provider: .claude, projectID: UUID(), title: "t", shouldLaunchOnOpen: true,
                                           createdAt: Date(timeIntervalSince1970: created), kind: kind)
            session.terminalCommand = command
            session.hasLaunchedInitialPrompt = started
            return session
        }
        XCTAssertTrue(AgentSessionStore.terminalCommandExpires(tab(created: 1_000_000), appLaunch: launch))
        XCTAssertFalse(AgentSessionStore.terminalCommandExpires(tab(created: 3_000_000), appLaunch: launch), "in diesem Lauf angelegt")
        XCTAssertFalse(AgentSessionStore.terminalCommandExpires(tab(created: 1_000_000, started: true), appLaunch: launch))
        XCTAssertFalse(AgentSessionStore.terminalCommandExpires(tab(created: 1_000_000, command: nil), appLaunch: launch),
                       "Login-Shell-Tab")
        XCTAssertFalse(AgentSessionStore.terminalCommandExpires(tab(created: 1_000_000, kind: .chat), appLaunch: launch))
    }

    /// Vic: Der Verfall läuft einmal je App-Lauf, nicht bei jedem schnellen Laden.
    func testExpiryRunsOncePerLaunchAndRetriesAfterAFailure() {
        struct Boom: Error {}
        let once = OncePerLaunch()
        var calls = 0
        XCTAssertThrowsError(try once.run { calls += 1; throw Boom() })
        XCTAssertFalse(once.hasRun, "gescheitert: nächster Aufruf versucht es erneut")
        try? once.run { calls += 1 }
        try? once.run { calls += 1 }
        try? once.run { calls += 1 }
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(once.hasRun)
    }

    // MARK: debug terminal

    func testDebugTerminalParsing() throws {
        XCTAssertEqual(try DebugCLIArguments.parse(["terminal", "abcd1234", "--text"], cwd: "/"),
                       .terminal(ref: "abcd1234", text: true, lines: nil))
        XCTAssertEqual(try DebugCLIArguments.parse(["terminal", "abcd1234", "--lines", "40"], cwd: "/"),
                       .terminal(ref: "abcd1234", text: false, lines: 40))
        XCTAssertThrowsError(try DebugCLIArguments.parse(["terminal"], cwd: "/"))
        XCTAssertThrowsError(try DebugCLIArguments.parse(["terminal", "a", "--lines", "0"], cwd: "/"))
    }

    func testTerminalTextIsTrimmedAndLimited() {
        let raw = "eins   \nzwei\r\n\ndrei\n\n   \n"
        XCTAssertEqual(AgentTerminalController.trimmedTerminalText(raw, lastLines: nil), "eins\nzwei\n\ndrei")
        XCTAssertEqual(AgentTerminalController.trimmedTerminalText(raw, lastLines: 2), "\ndrei")
    }

    // MARK: PID in chats show

    func testShowCarriesThePidOfTheRunningProcess() {
        let runtime = ChatsRuntimeInfo(status: .idle, source: "app", since: nil, revision: nil,
                                       transcriptPath: nil, transcriptSizeBytes: nil, availability: .missingTranscript)
        let session = AgentChatSession(provider: .codex, projectID: UUID(), title: "c")
        let entry = ChatsSessionEntry(session: session, projectName: "p", projectPath: "/tmp/p")
        let running = ChatsLiveStatus(runtimeStatus: .idle, isAttachedPTY: true, canSend: true, canInterrupt: false, pid: 4711)
        let withPid = ChatsOutput.sessionJSON(entry: entry, runtime: runtime, selfID: nil, live: true, liveStatus: running)
        XCTAssertEqual((withPid["runtime"] as? [String: Any])?["pid"] as? Int32, 4711)
        let detached = ChatsOutput.sessionJSON(entry: entry, runtime: runtime, selfID: nil, live: true,
                                               liveStatus: .detached)
        XCTAssertNil((detached["runtime"] as? [String: Any])?["pid"])
    }

    /// Befund aus der Test-Instanz: Int32 kam als null an.
    func testLivePIDSurvivesTheJSONBridge() {
        XCTAssertEqual(ChatsControlJSON(any: AgentControlRequestHandler.livePID(4711)).intValue, 4711)
        XCTAssertNil(ChatsControlJSON(any: AgentControlRequestHandler.livePID(nil)).intValue)
    }

    // MARK: ruhige Zeile bei altem Build

    func testOldAppWithoutHandoverIsAClassicRestart() {
        let old = ChatsControlResponse.failure(requestID: "r", code: .unsupported, message: "Unbekannte Methode: app.handover")
        XCTAssertTrue(AppCLICommand.isUnknownMethod(old))
        XCTAssertFalse(AppCLICommand.isUnknownMethod(.failure(requestID: "r", code: .conflict, message: "busy")))
        XCTAssertFalse(AppCLICommand.oldAppLine.contains("Unbekannte Methode"), "ruhige Zeile statt Fehler")
    }

    /// Dex: feste Namen in `session_notification_posted kind=…`.
    func testNotificationLogLabels() {
        XCTAssertEqual(AgentSessionUserNotification.Kind.turnCompleted.logLabel, "turnCompleted")
        XCTAssertEqual(AgentSessionUserNotification.Kind.subagentCompleted.logLabel, "subagentCompleted")
        XCTAssertEqual(AgentSessionUserNotification.Kind.subagentFailed.logLabel, "subagentFailed")
    }
}

/// Vic (Phase 2): Die Zähler-Prüfung verlangt jede Zahl rund um die Übergabe
/// genau einmal und in Reihenfolge; die Stelle ist bei 5 Zahlen je Sekunde nach
/// 10 s aus dem Bild. `debug terminal` muss deshalb den Rücklauf liefern.
@MainActor
final class ChatsTerminalScrollbackTests: XCTestCase {
    func testPlainTextCarriesTheScrollbackCompleteAndInOrder() {
        let controller = AgentTerminalController(
            sessionID: UUID(),
            command: AgentLaunchCommand(executablePath: "/bin/sh", arguments: [], workingDirectory: "/tmp",
                                        keyboardProfile: .plainShell),
            onLaunched: {}, onTerminated: { _ in })
        let text = (1...300).map { "z\($0)" }.joined(separator: "\r\n") + "\r\n"
        controller.terminal.feed(byteArray: Array(text.utf8)[...])
        let lines = controller.plainText().components(separatedBy: "\n").filter { $0.hasPrefix("z") }
        XCTAssertEqual(lines, (1...300).map { "z\($0)" }, "jede Zahl genau einmal, in Reihenfolge, auch aus dem Rücklauf")
        XCTAssertEqual(controller.plainText(lastLines: 3).components(separatedBy: "\n"), ["z298", "z299", "z300"])
    }
}
