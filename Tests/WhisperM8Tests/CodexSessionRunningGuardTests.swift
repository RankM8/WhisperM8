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
                       terminating: [Int32: UUID] = [:], former: [Int32: UUID] = [:]) -> CodexRunningConflict? {
        G.conflict(sessionID: thread, localID: me, appChats: chats, processes: processes,
                   terminatingOwner: { pid, _ in terminating[pid] }, formerOwner: { pid, _ in former[pid] },
                   titleOf: { $0 == self.other ? "Anderer Chat" : "?" })
    }

    private func target(_ pid: Int32, start: UInt64? = nil) -> CodexProcessTarget {
        CodexProcessTarget(pid: pid, startTime: start, sessionID: thread)
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
        XCTAssertEqual(check(processes: [tui(700)]), .outsideApp(process: target(700), inTerminal: true))
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
        XCTAssertEqual(check(processes: [job]), .outsideApp(process: target(800), inTerminal: false))
    }

    // (d) Tab-Neustart: der eigene Vorgänger läuft aus und sperrt nicht.
    func testOwnTerminatingPredecessorDoesNotBlockButOtherChatsDoes() {
        // PTY-Prozess 900 wurde beendet; codex 902 hängt hinter Wrappern.
        XCTAssertNil(check(processes: [tui(902, leader: 900)], terminating: [900: me]))
        XCTAssertNil(check(processes: [tui(900)], terminating: [900: me]), "Programm direkt im PTY")
        XCTAssertEqual(check(processes: [tui(902, leader: 900)], terminating: [900: other]),
                       .otherChatEnding(title: "Anderer Chat", process: target(902)),
                       "ein anderer, gerade geschlossener Chat schreibt noch")
    }

    /// Jarvis: Überlebt der eigene Prozess das Schließen länger als 30 s,
    /// sperrt er — aber als „voriger Lauf dieses Chats“, nicht „außerhalb“.
    func testOwnPreviousRunBeyondWindowIsNamedCorrectly() {
        XCTAssertEqual(check(processes: [tui(902, leader: 900)], former: [900: me]), .ownPreviousRun(process: target(902)))
        XCTAssertEqual(check(processes: [tui(902, leader: 900)], former: [900: other]),
                       .otherChatEnding(title: "Anderer Chat", process: target(902)), "mit PID für den Ausweg")
        XCTAssertNil(check(processes: [tui(902, leader: 900)], terminating: [900: me], former: [900: me]),
                     "innerhalb von 30 s läuft der eigene Vorgänger aus")
    }

    func testEndableProcessOnlyForProcessConflicts() {
        XCTAssertNil(CodexRunningConflict.otherChat(title: "x").endableProcess, "laufender Chat: dort schließen")
        XCTAssertEqual(CodexRunningConflict.ownPreviousRun(process: target(5, start: 1)).endableProcess, target(5, start: 1))
        XCTAssertEqual(CodexRunningConflict.outsideApp(process: target(6, start: 1), inTerminal: false).endableProcess,
                       target(6, start: 1))
        XCTAssertNil(CodexRunningConflict.outsideApp(process: target(7), inTerminal: true).endableProcess,
                     "ohne Startzeit kein Knopf: die Prüfung vor dem Signal wäre unvollständig")
    }

    func testConflictPassesStartTimesToTheLedger() {
        var asked: [(Int32, UInt64?)] = []
        var proc = tui(902, leader: 900); proc.startTime = 5; proc.leaderStartTime = 4
        _ = G.conflict(sessionID: thread, localID: me, appChats: [], processes: [proc],
                       terminatingOwner: { asked.append(($0, $1)); return nil },
                       formerOwner: { _, _ in nil }, titleOf: { _ in "" })
        XCTAssertEqual(asked.map(\.0), [902, 900])
        XCTAssertEqual(asked.map(\.1), [5, 4])
    }

    /// Ein lebender Chat der App geht vor einem 24-h-Eintrag: nie ein
    /// „beendeter Lauf“ mit Beenden-Knopf für einen laufenden Chat.
    func testRunningAppChatWinsOverFormerOwner() {
        let running = G.AppChat(id: other, title: "Läuft", sessionID: nil, processID: 900)
        XCTAssertEqual(check([running], processes: [tui(902, leader: 900)], former: [900: other]),
                       .otherChat(title: "Läuft"))
    }

    /// Vic: Vor „Prozess beenden“ muss unter der PID noch derselbe Prozess laufen.
    func testIsStillTargetChecksNameArgumentsAndStartTime() {
        var proc = tui(42); proc.startTime = 1000
        let t = target(42, start: 1000)
        XCTAssertTrue(G.isStillTarget(t, current: proc, currentName: "codex"))
        XCTAssertFalse(G.isStillTarget(t, current: proc, currentName: "zsh"), "anderer Name")
        var later = proc; later.startTime = 2000
        XCTAssertFalse(G.isStillTarget(t, current: later, currentName: "codex"), "PID neu vergeben")
        XCTAssertFalse(G.isStillTarget(t, current: tui(42, id: "anderer"), currentName: "codex"), "andere Sitzung")
        XCTAssertFalse(G.isStillTarget(t, current: nil, currentName: nil), "nicht mehr da")
        XCTAssertTrue(G.isStillTarget(target(42), current: later, currentName: "codex"), "ohne bekannte Startzeit")
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
        blocked.codexRunningConflict = { _, _ in .outsideApp(process: self.target(4242), inTerminal: true) }
        XCTAssertThrowsError(try blocked.command(for: codexChat("Ich"), project: project)) {
            XCTAssertTrue($0.localizedDescription.contains("4242"))
            XCTAssertTrue($0.localizedDescription.contains("WhisperM8"), "nennt: außerhalb der App")
        }
        blocked.codexRunningConflict = { _, _ in .outsideApp(process: self.target(4243), inTerminal: false) }
        XCTAssertThrowsError(try blocked.command(for: codexChat("Ich"), project: project)) {
            XCTAssertTrue($0.localizedDescription.contains("4243"))
            XCTAssertTrue($0.localizedDescription.contains("End Process"), "verweist auf den Knopf")
        }
        blocked.codexRunningConflict = { _, _ in .otherChatEnding(title: "Alter Chat", process: self.target(4245)) }
        XCTAssertThrowsError(try blocked.command(for: codexChat("Ich"), project: project)) {
            XCTAssertTrue($0.localizedDescription.contains("Alter Chat"))
            XCTAssertTrue($0.localizedDescription.contains("4245"), "Vic: PID auch beim anderen Chat")
        }
        blocked.codexRunningConflict = { _, _ in .ownPreviousRun(process: self.target(4244)) }
        XCTAssertThrowsError(try blocked.command(for: codexChat("Ich"), project: project)) {
            XCTAssertTrue($0.localizedDescription.contains("4244"))
            XCTAssertFalse($0.localizedDescription.contains("outside"), "nicht „außerhalb“")
        }
    }

    /// Notbremse `codexStartGuardEnabled`: aus = keine Prüfung, keine Reservierung.
    func testKillSwitchTurnsTheGuardOff() throws {
        var off = builder()
        off.codexStartGuardEnabled = false
        off.codexRunningConflict = { _, _ in .outsideApp(process: self.target(1), inTerminal: true) }
        off.launchReservation = { _, _ in "anderer" }
        XCTAssertEqual(try off.command(for: codexChat("Ich"), project: project).arguments.last, thread)
        XCTAssertTrue(AppPreferences(defaults: UserDefaults(suiteName: "wm8-codexguard-\(UUID())")!)
            .isCodexStartGuardEnabled, "Standard an")
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
    func testFormerOwnerOutlivesTheWindow() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = ProcessTerminationLedger(window: 30, now: { clock }, startTimeOf: { _ in nil })
        let chat = UUID()
        ledger.noteTerminating(pid: 20, localID: chat)
        clock = clock.addingTimeInterval(120)
        XCTAssertNil(ledger.owner(ofTerminating: 20))
        XCTAssertFalse(ledger.isBeingTerminated(pid: 20, forLocalID: chat), "sperrt wieder")
        XCTAssertEqual(ledger.formerOwner(of: 20), chat, "aber die Meldung kennt den Chat")
        clock = clock.addingTimeInterval(25 * 60 * 60)
        XCTAssertNil(ledger.formerOwner(of: 20))
    }

    /// Vic: Eine binnen 24 h neu vergebene PID darf nicht den alten Chat nennen.
    func testReusedPIDDoesNotMatchTheOldChat() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = ProcessTerminationLedger(window: 30, now: { clock }, startTimeOf: { _ in 111 })
        let chat = UUID()
        ledger.noteTerminating(pid: 30, localID: chat)
        XCTAssertEqual(ledger.owner(ofTerminating: 30, startTime: 111), chat)
        XCTAssertNil(ledger.owner(ofTerminating: 30, startTime: 222))
        clock = clock.addingTimeInterval(3600)
        XCTAssertEqual(ledger.formerOwner(of: 30, startTime: 111), chat)
        XCTAssertNil(ledger.formerOwner(of: 30, startTime: 222), "andere Startzeit = anderer Prozess")
        XCTAssertEqual(ledger.formerOwner(of: 30, startTime: nil), chat, "ohne Startzeit wie bisher")
    }

    /// Beim Vermerk schon abgeholt (keine Startzeit): passt nur auf einen
    /// Prozess, der vorher lief, nie auf eine später vergebene PID.
    func testEntryWithoutStartTimeNeverMatchesALaterProcess() {
        let noted = Date(timeIntervalSince1970: 1_800_000_000)
        var clock = noted
        let ledger = ProcessTerminationLedger(window: 30, now: { clock }, startTimeOf: { _ in nil })
        let chat = UUID()
        ledger.noteTerminating(pid: 40, localID: chat)
        clock = noted.addingTimeInterval(3600)
        let earlier = UInt64((noted.timeIntervalSince1970 - 60) * 1_000_000)
        let later = UInt64((noted.timeIntervalSince1970 + 600) * 1_000_000)
        XCTAssertEqual(ledger.formerOwner(of: 40, startTime: earlier), chat)
        XCTAssertNil(ledger.formerOwner(of: 40, startTime: later), "PID danach neu vergeben")
    }

    func testStartTimeSmoke() {
        let own = ProcessStartTime.microseconds(pid: getpid())
        XCTAssertNotNil(own)
        XCTAssertEqual(own, ProcessStartTime.microseconds(pid: getpid()), "stabil")
        XCTAssertNil(ProcessStartTime.microseconds(pid: 0))
        XCTAssertNotNil(ProcessStartTime.of(pid: getpid()))
    }

    func testOwnerOfTerminatingProcess() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = ProcessTerminationLedger(window: 30, now: { clock }, startTimeOf: { _ in nil })
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

/// „Prozess beenden“: erst SIGTERM, SIGKILL nur auf ausdrücklichen Wunsch,
/// vor jedem Signal erneute Prüfung.
final class CodexProcessTerminatorTests: XCTestCase {
    private let thread = "019a6f2e-1c2d-7e3f-8a9b-0c1d2e3f4a5b"

    private func make(name: String? = "codex", start: UInt64 = 1000, exitsAfterSignal: Bool = true,
                      alreadyGone: Bool = false, signals: Box) -> CodexProcessTerminator {
        var terminator = CodexProcessTerminator()
        terminator.read = { pid in
            (CodexProcess(pid: pid, sessionLeader: pid, arguments: ["resume", self.thread], startTime: start), name)
        }
        terminator.signal = { _, sig in signals.values.append(sig); return 0 }
        terminator.hasExited = { _ in alreadyGone }
        terminator.waitForExit = { _, _ in exitsAfterSignal }
        return terminator
    }

    final class Box { var values: [Int32] = [] }

    private var target: CodexProcessTarget { CodexProcessTarget(pid: 77, startTime: 1000, sessionID: thread) }

    func testSendsSIGTERMFirst() async {
        let signals = Box()
        let outcome = await make(signals: signals).end(target, force: false)
        XCTAssertEqual(outcome, .ended)
        XCTAssertEqual(signals.values, [SIGTERM])
    }

    func testSIGKILLOnlyWhenForced() async {
        let signals = Box()
        let stubborn = make(exitsAfterSignal: false, signals: signals)
        let first = await stubborn.end(target, force: false)
        XCTAssertEqual(first, .stillRunning)
        let second = await stubborn.end(target, force: true)
        XCTAssertEqual(second, .stillRunning)
        XCTAssertEqual(signals.values, [SIGTERM, SIGKILL])
    }

    func testNoSignalWhenThePIDNowBelongsToAnotherProcess() async {
        let signals = Box()
        let reused = await make(start: 2000, signals: signals).end(target, force: true)
        XCTAssertEqual(reused, .notTheSameProcess)
        let renamed = await make(name: "zsh", signals: signals).end(target, force: false)
        XCTAssertEqual(renamed, .notTheSameProcess)
        XCTAssertTrue(signals.values.isEmpty, "nie ein Signal an einen fremden Prozess")
    }

    func testFailedSignalIsReportedNotRetriedForever() async {
        var terminator = make(signals: Box())
        terminator.signal = { _, _ in -1 }
        let outcome = await terminator.end(target, force: true)
        if case .signalFailed = outcome {} else { XCTFail("erwartet signalFailed, war \(outcome)") }
    }

    func testAlreadyGoneIsEndedWithoutSignal() async {
        let signals = Box()
        let outcome = await make(alreadyGone: true, signals: signals).end(target, force: false)
        XCTAssertEqual(outcome, .ended)
        XCTAssertTrue(signals.values.isEmpty)
    }
}
