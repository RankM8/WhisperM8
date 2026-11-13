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

    private func tui(_ pid: Int32, parent: Int32 = 1, id: String? = nil) -> CodexProcess {
        CodexProcess(pid: pid, parentPID: parent,
                     arguments: ["resume", "-C", "/repo mit Leerzeichen", "-m", "gpt-5.5", id ?? thread])
    }

    // (a) Zwei Chats der App: der andere läuft schon.
    func testOtherAppChatOnSameThreadBlocksAndNamesIt() {
        let running = G.AppChat(id: other, title: "Anderer Chat", sessionID: thread.uppercased(), processID: 500)
        XCTAssertEqual(check([running], processes: []), .otherChat(title: "Anderer Chat"))
        XCTAssertEqual(check([running], processes: nil), .otherChat(title: "Anderer Chat"),
                       "die eigene Tabelle gilt auch ohne Prozessliste")
        // Über den Prozess: Kind des Node-Wrappers eines anderen Chats.
        let unbound = G.AppChat(id: other, title: "Anderer Chat", sessionID: nil, processID: 500)
        XCTAssertEqual(check([unbound], processes: [tui(501, parent: 500)]), .otherChat(title: "Anderer Chat"))
    }

    // (b) Codex im normalen Terminal.
    func testCodexInTerminalBlocksAsOutsideApp() {
        XCTAssertEqual(check(processes: [tui(700)]), .outsideApp(pid: 700))
        XCTAssertNil(check(processes: [tui(700, id: "anderer-thread")]), "andere Sitzung")
        let fresh = CodexProcess(pid: 701, parentPID: 1, arguments: ["-C", "/repo", thread])
        XCTAssertNil(check(processes: [fresh]), "ohne resume kein Fortsetzen")
    }

    // (c) Verwaister Subagent-Job nach gestorbenem Supervisor.
    func testOrphanedExecResumeBlocks() {
        let job = CodexProcess(pid: 800, parentPID: 1,
                               arguments: ["-a", "never", "exec", "resume", "--json", thread, "weiter"])
        XCTAssertEqual(check(processes: [job]), .outsideApp(pid: 800))
    }

    // (d) Tab-Neustart: der eigene Vorgänger läuft aus und sperrt nicht.
    func testOwnTerminatingPredecessorDoesNotBlockButOtherChatsDoes() {
        // Wrapper 900 wurde beendet, sein Kind 901 trägt die Argumente.
        XCTAssertNil(check(processes: [tui(901, parent: 900)], terminating: [900: me]))
        XCTAssertNil(check(processes: [tui(900)], terminating: [900: me]), "Programm direkt im PTY")
        XCTAssertEqual(check(processes: [tui(901, parent: 900)], terminating: [900: other]),
                       .otherChat(title: "Anderer Chat"), "ein anderer, gerade geschlossener Chat schreibt noch")
    }

    func testUnreadableProcessListNeverBlocks() {
        XCTAssertNil(check(processes: nil), "im Zweifel starten")
        XCTAssertNil(check(processes: []))
    }

    func testOwnRunningProcessIsIgnored() {
        let mine = G.AppChat(id: me, title: "Ich", sessionID: thread, processID: 950)
        XCTAssertNil(check([mine], processes: [tui(951, parent: 950)]))
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
        blocked.codexRunningConflict = { _, _ in .outsideApp(pid: 4242) }
        XCTAssertThrowsError(try blocked.command(for: codexChat("Ich"), project: project)) {
            XCTAssertTrue($0.localizedDescription.contains("4242"))
            XCTAssertTrue($0.localizedDescription.contains("WhisperM8"), "nennt: außerhalb der App")
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
