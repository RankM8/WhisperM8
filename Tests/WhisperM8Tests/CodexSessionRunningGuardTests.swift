import XCTest
@testable import WhisperM8

/// Doppelstart-Sperre für Codex (13.11.2026). Die vier Wege aus der Analyse:
/// (a) zwei Chats der App auf derselben Codex-ID, (b) Codex läuft schon im
/// Terminal, (c) verwaister `exec resume` eines Subagent-Jobs, (d) Neustart
/// des Tabs mit auslaufendem Vorgänger.
final class CodexSessionRunningGuardTests: XCTestCase {
    typealias G = CodexSessionRunningGuard
    private let thread = "019a6f2e-1c2d-7e3f-8a9b-0c1d2e3f4a5b"
    private let me = UUID(), other = UUID()

    private func check(_ chats: [G.AppChat] = [], processes: [CodexProcess]?,
                       terminating: [Int32: UUID] = [:]) -> CodexRunningConflict? {
        G.conflict(sessionID: thread, localID: me, appChats: chats, processes: processes,
                   terminatingOwner: { terminating[$0] }, titleOf: { $0 == self.other ? "Anderer Chat" : "?" })
    }

    private func tui(_ pid: Int32, leader: Int32? = nil, id: String? = nil, terminal: Bool = true) -> CodexProcess {
        CodexProcess(pid: pid, sessionLeader: leader ?? pid,
                     arguments: ["resume", "-C", "/repo mit Leerzeichen", "-m", "gpt-5.5", id ?? thread],
                     hasTerminal: terminal)
    }

    // (a) Zwei Chats der App: der andere läuft schon.
    func testOtherAppChatOnSameThreadBlocksAndNamesIt() {
        let running = G.AppChat(id: other, title: "Anderer Chat", sessionID: thread.uppercased(), processID: 500)
        XCTAssertEqual(check([running], processes: []), .otherChat(title: "Anderer Chat"))
        XCTAssertEqual(check([running], processes: nil), .otherChat(title: "Anderer Chat"),
                       "die eigene Tabelle gilt auch ohne Prozessliste")
        // Über den Prozess: hinter Wrappern (Node, Volta) eines anderen Chats
        // oder in einem Terminal-Tab — der PTY-Prozess ist Sitzungsführer.
        let unbound = G.AppChat(id: other, title: "Anderer Chat", sessionID: nil, processID: 500)
        XCTAssertEqual(check([unbound], processes: [tui(503, leader: 500)]), .otherChat(title: "Anderer Chat"))
    }

    // (b) Codex im normalen Terminal.
    func testCodexInTerminalBlocksAsOutsideApp() {
        XCTAssertEqual(check(processes: [tui(700)]), .outsideApp(pid: 700, inTerminal: true))
        XCTAssertNil(check(processes: [tui(700, id: "anderer-thread")]), "andere Sitzung")
        let fresh = CodexProcess(pid: 701, sessionLeader: 701, arguments: ["-C", "/repo", thread])
        XCTAssertNil(check(processes: [fresh]), "ohne resume kein Fortsetzen")
        let prompt = CodexProcess(pid: 702, sessionLeader: 702, arguments: ["exec", "bitte resume \(thread) prüfen"])
        XCTAssertNil(check(processes: [prompt]), "ID nur im Prompt-Text")
        let configValue = CodexProcess(pid: 703, sessionLeader: 703, arguments: ["-c", "resume", thread + "x"])
        XCTAssertNil(check(processes: [configValue]), "ID muss ein eigenes Argument sein")
        let daemon = CodexProcess(pid: 704, sessionLeader: 704,
                                  arguments: ["app-server", "--listen", "unix://", "--managed-daemon"])
        XCTAssertNil(check(processes: [daemon]), "Hintergrunddienst")
    }

    // (c) Verwaister Subagent-Job nach gestorbenem Supervisor.
    func testOrphanedExecResumeBlocks() {
        let job = CodexProcess(pid: 800, sessionLeader: 800,
                               arguments: ["-a", "never", "exec", "resume", "--json", thread, "weiter"],
                               hasTerminal: false)
        XCTAssertEqual(check(processes: [job]), .outsideApp(pid: 800, inTerminal: false))
    }

    // (d) Tab-Neustart: der eigene Vorgänger läuft aus und sperrt nicht.
    func testOwnTerminatingPredecessorDoesNotBlockButOtherChatsDoes() {
        // PTY-Prozess 900 wurde beendet; codex 902 hängt hinter Wrappern.
        XCTAssertNil(check(processes: [tui(902, leader: 900)], terminating: [900: me]))
        XCTAssertNil(check(processes: [tui(900)], terminating: [900: me]), "Programm direkt im PTY")
        XCTAssertEqual(check(processes: [tui(902, leader: 900)], terminating: [900: other]),
                       .otherChatEnding(title: "Anderer Chat"), "ein anderer, gerade geschlossener Chat schreibt noch")
    }

    func testUnreadableProcessListNeverBlocks() {
        XCTAssertNil(check(processes: nil), "im Zweifel starten")
        XCTAssertNil(check(processes: []))
    }

    func testOwnRunningProcessIsIgnored() {
        let mine = G.AppChat(id: me, title: "Ich", sessionID: thread, processID: 950)
        XCTAssertNil(check([mine], processes: [tui(951, leader: 950)]))
    }

    func testResumedIDFromLaunchArguments() {
        XCTAssertEqual(G.resumedID(inLaunchArguments: ["resume", "-C", "/r", thread]), thread)
        XCTAssertNil(G.resumedID(inLaunchArguments: ["-C", "/r", "Prompt"]))
    }

    func testParseProcArgs() {
        func bytes(_ argv: [String], exec: String = "/opt/codex") -> [UInt8] {
            var out = withUnsafeBytes(of: Int32(argv.count).littleEndian) { Array($0) }
            out += Array(exec.utf8) + [0, 0, 0]
            for arg in argv { out += Array(arg.utf8) + [0] }
            return out + Array("PATH=/bin".utf8) + [0]
        }
        XCTAssertEqual(G.parseProcArgs(bytes(["codex", "resume", "-C", "/a b", thread])),
                       ["resume", "-C", "/a b", thread])
        XCTAssertNil(G.parseProcArgs([1, 0]))
        XCTAssertNil(G.parseProcArgs(Array(bytes(["codex", "resume"]).prefix(12))), "abgeschnitten")
        XCTAssertEqual(G.parseProcArgs(bytes(["codex", "", "resume"])), ["", "resume"], "leeres Argument in der Mitte")
    }

    func testProcessNames() {
        XCTAssertTrue(G.isCodexName("codex"))
        XCTAssertTrue(G.isCodexName("codex-aarch64-apple-darwin"))
        XCTAssertFalse(G.isCodexName("node"))
        XCTAssertFalse(G.isCodexName("codexbar"))
    }

    /// Klebecode der Detailansicht: fortgesetzte ID vor gebundener, nur Codex
    /// trägt eine Sitzung, Terminal-Tabs zählen für die PID-Zuordnung.
    func testAppChatsFromControllers() {
        let project = UUID()
        let codex = AgentChatSession(provider: .codex, projectID: project, externalSessionID: "gebunden", title: "Codex")
        let claude = AgentChatSession(provider: .claude, projectID: project, externalSessionID: thread, title: "Claude")
        var shell = AgentChatSession(provider: .codex, projectID: project, title: "")
        shell.kind = .terminal
        let chats = G.appChats(
            controllers: [(codex.id, ["resume", "-C", "/r", thread], 10), (claude.id, ["--resume", thread], 11),
                          (shell.id, [], 12), (UUID(), [], 13)],
            sessions: [codex.id: codex, claude.id: claude, shell.id: shell])
        XCTAssertEqual(chats.count, 3, "unbekannter Controller fällt weg")
        XCTAssertEqual(chats[0].sessionID, thread, "fortgesetzte ID vor gebundener")
        XCTAssertNil(chats[1].sessionID, "Claude trägt keine Codex-Sitzung")
        XCTAssertNil(chats[2].sessionID)
        XCTAssertEqual(chats[2].processID, 12)
        XCTAssertFalse(chats[2].title.isEmpty, "leerer Titel wird Kurz-ID")
    }

    func testLiveLookupIsOffOutsideTheApp() {
        XCTAssertEqual(G.liveCodexProcesses(), [], "unter swift test keine echten Prozesse")
    }

    // MARK: Builder

    private let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)

    private func builder() -> AgentCommandBuilder {
        var builder = AgentCommandBuilder(commandResolver: { "/usr/local/bin/\($0)" })
        builder.gptFastModeEnabledResolver = { false }
        builder.extraArgumentsResolver = { _ in [] }
        builder.codexServiceTierResolver = { .fast }
        return builder
    }

    private func codexChat(_ title: String) -> AgentChatSession {
        AgentChatSession(provider: .codex, projectID: project.id, externalSessionID: thread, title: title,
                         hasLaunchedInitialPrompt: true)
    }

    func testBuilderRefusesResumeWithClearMessages() {
        var blocked = builder()
        blocked.codexRunningConflict = { _, _ in .otherChat(title: "Anderer Chat") }
        XCTAssertThrowsError(try blocked.command(for: codexChat("Ich"), project: project)) {
            XCTAssertEqual($0 as? AgentCommandError,
                           .codexSessionRunning(title: "Ich", conflict: .otherChat(title: "Anderer Chat")))
            XCTAssertTrue($0.localizedDescription.contains("Anderer Chat"))
        }
        blocked.codexRunningConflict = { _, _ in .outsideApp(pid: 4242, inTerminal: true) }
        XCTAssertThrowsError(try blocked.command(for: codexChat("Ich"), project: project)) {
            XCTAssertTrue($0.localizedDescription.contains("4242"))
            XCTAssertTrue($0.localizedDescription.contains("WhisperM8"), "nennt: außerhalb der App")
        }
        blocked.codexRunningConflict = { _, _ in .outsideApp(pid: 4243, inTerminal: false) }
        XCTAssertThrowsError(try blocked.command(for: codexChat("Ich"), project: project)) {
            XCTAssertTrue($0.localizedDescription.contains("kill 4243"), "Ausweg ohne Terminalfenster")
        }
        blocked.codexRunningConflict = { _, _ in .otherChatEnding(title: "Alter Chat") }
        XCTAssertThrowsError(try blocked.command(for: codexChat("Ich"), project: project)) {
            XCTAssertTrue($0.localizedDescription.contains("Alter Chat"))
        }
    }

    func testSimultaneousCodexResumesStartOnlyOnce() throws {
        let reservations = ClaudeSessionLaunchReservations()
        var reserving = builder()
        reserving.launchReservation = { reservations.reserve(sessionID: $0, for: $1)?.uuidString }
        let first = codexChat("erster"), second = codexChat("zweiter")
        XCTAssertEqual(try reserving.command(for: first, project: project).arguments.last, thread)
        XCTAssertThrowsError(try reserving.command(for: second, project: project)) {
            XCTAssertEqual($0 as? AgentCommandError,
                           .sessionStartingElsewhere(title: "zweiter", otherChat: first.id.uuidString))
        }
        XCTAssertEqual(try reserving.command(for: first, project: project).arguments.last, thread, "Tab-Neustart")
        XCTAssertNil(reservations.reserve(sessionID: thread, for: UUID()), "eigener Schlüssel, kein Konflikt mit Claude")
    }

    func testNewCodexChatIsNeverChecked() throws {
        var checking = builder()
        checking.codexRunningConflict = { _, _ in XCTFail("neuer Chat setzt nichts fort"); return nil }
        let fresh = AgentChatSession(provider: .codex, projectID: project.id, title: "Neu", initialPrompt: "los")
        XCTAssertEqual(try checking.command(for: fresh, project: project).arguments.last, "los")
    }
}

final class ProcessTerminationLedgerOwnerTests: XCTestCase {
    func testOwnerOfTerminatingProcess() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = ProcessTerminationLedger(window: 30, now: { clock })
        let chat = UUID()
        ledger.noteTerminating(pid: 10, localID: chat)
        ledger.noteTerminating(pid: 11)
        XCTAssertEqual(ledger.owner(ofTerminating: 10), chat)
        XCTAssertNil(ledger.owner(ofTerminating: 11), "ohne vermerkten Chat")
        XCTAssertNil(ledger.owner(ofTerminating: 12))
        clock = clock.addingTimeInterval(31)
        XCTAssertNil(ledger.owner(ofTerminating: 10), "abgelaufen")
    }
}
