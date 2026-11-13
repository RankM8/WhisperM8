import Foundation
import XCTest
@testable import WhisperM8

/// Codex schreibt während einer Antwort nichts ins Rollout (Testlauf
/// 13.11.2026: 4 min 46 s Stille bei 300 Zeilen Antwort). Ein offener Turn
/// gilt deshalb als Arbeit, solange der Codex-Prozess des Chats lebt und der
/// Turn zu ihm gehört — App (Watcher) und CLI (`ChatsStatusProbe`) über
/// denselben Decider.
final class CodexOpenTurnStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var processStart: Date { now.addingTimeInterval(-600) }
    private var turnStart: Date { now.addingTimeInterval(-300) }
    /// 5 min Stille: weit über der 120-s-Sicherung.
    private var silentMTime: Date { now.addingTimeInterval(-286) }

    private func decide(
        _ event: AgentTranscriptEvent,
        mtime: Date,
        process: CodexProcessLiveness
    ) -> AgentTranscriptStatusDecider.Decision? {
        AgentTranscriptStatusDecider.decide(
            lastEvent: event, fileMTime: mtime, now: now, priorTurnFinishedAt: nil, codexProcess: process)
    }

    private func line(_ type: String, _ payload: String, at date: Date) -> String {
        let stamp = ISO8601DateFormatter().string(from: date)
        return #"{"timestamp":"\#(stamp)","type":"\#(type)","payload":\#(payload)}"#
    }

    // MARK: - Der Befund aus dem Testlauf

    func testLongAnswerWithLiveProcessStaysWorking() {
        // Echte Reihenfolge aus dem Testchat: task_started, Denkschritt, dann
        // nichts mehr, während Codex sichtbar schreibt.
        let tail = [
            line("event_msg", #"{"type":"task_started","turn_id":"t"}"#, at: turnStart),
            line("response_item", #"{"type":"reasoning","id":"rs"}"#, at: turnStart.addingTimeInterval(5)),
        ].joined(separator: "\n")
        let event = AgentTranscriptParser.lastEvent(in: tail, provider: .codex)
        XCTAssertEqual(decide(event!, mtime: silentMTime, process: .running(since: processStart))?.status, .working)
        // Ohne Prozesswissen bleibt es beim alten Verhalten.
        XCTAssertEqual(decide(event!, mtime: silentMTime, process: .unknown)?.status, .idle)
    }

    func testOpenTurnKindsAllFollowTheProcess() {
        for event: AgentTranscriptEvent in [
            .userMessage(timestamp: turnStart),
            .assistantMessageOngoing(timestamp: turnStart),
            .toolResult(timestamp: turnStart),
        ] {
            XCTAssertEqual(decide(event, mtime: silentMTime, process: .running(since: processStart))?.status,
                           .working, "\(event)")
        }
    }

    func testFinishedAndAbortedTurnsStayIdleWithLiveProcess() {
        let done = decide(.assistantMessageStopped(timestamp: turnStart, stopReason: "task_complete"),
                          mtime: now, process: .running(since: processStart))
        XCTAssertEqual(done?.status, .idle)
        XCTAssertEqual(done?.turnFinished, true)
        XCTAssertEqual(decide(.turnInterrupted(timestamp: turnStart), mtime: now,
                              process: .running(since: processStart))?.status, .idle)
    }

    // MARK: - Freigabe und Rückfrage: Grün heißt nur „arbeitet“

    func testUserQuestionToolIsNeverWorking() {
        let event = AgentTranscriptParser.parseLine(
            line("response_item", #"{"type":"function_call","name":"request_user_input","arguments":"{}","call_id":"c"}"#,
                 at: turnStart),
            provider: .codex)
        guard case .toolCallPending(_, true) = event else { return XCTFail("Rückfrage erwartet: \(String(describing: event))") }
        // Sofort, auch bei frischer Datei und lebendem Prozess.
        XCTAssertEqual(decide(event!, mtime: now, process: .running(since: processStart))?.status, .idle)
    }

    func testPendingToolCallKeepsTheTwoMinuteLimitDespiteLiveProcess() {
        // Freigabe-Anfragen stehen nicht im Rollout: Ein offener Aufruf kann
        // auf den Nutzer warten. Höchstens 2 min grün, nie dauerhaft.
        let event = AgentTranscriptParser.parseLine(
            line("response_item", #"{"type":"custom_tool_call","name":"exec","input":"ls","call_id":"c"}"#, at: turnStart),
            provider: .codex)
        guard case .toolCallPending(_, false) = event else { return XCTFail("offener Aufruf erwartet") }
        XCTAssertEqual(decide(event!, mtime: now.addingTimeInterval(-30), process: .running(since: processStart))?.status,
                       .working)
        XCTAssertEqual(decide(event!, mtime: silentMTime, process: .running(since: processStart))?.status, .idle)
    }

    func testLocalShellCallIsAPendingToolCall() {
        let event = AgentTranscriptParser.parseLine(
            line("response_item", #"{"type":"local_shell_call","call_id":"c"}"#, at: turnStart), provider: .codex)
        guard case .toolCallPending(_, false) = event else { return XCTFail("offener Aufruf erwartet") }
    }

    // MARK: - Prozess tot, früherer Lauf, Hänger

    func testDeadProcessWithOpenTurnIsNotWorking() {
        for event: AgentTranscriptEvent in [
            .userMessage(timestamp: now), .assistantMessageOngoing(timestamp: now),
            .toolResult(timestamp: now), .toolCallPending(timestamp: now, waitsForUser: false),
        ] {
            XCTAssertEqual(decide(event, mtime: now, process: .notRunning)?.status, .idle, "\(event)")
        }
    }

    func testOpenTurnFromBeforeACrashIsNotWorkingForTheResumedProcess() {
        // Absturz mitten im Turn, Stunden später Resume: Der neue Prozess
        // wartet am Prompt, der offene Turn gehört dem alten Lauf. Ein Resume
        // schreibt Meta-Zeilen (mtime frisch), aber kein neues Turn-Ereignis.
        let resumed = CodexProcessLiveness.running(since: now.addingTimeInterval(-20))
        let oldTurn = now.addingTimeInterval(-3 * 3600)
        XCTAssertEqual(decide(.assistantMessageOngoing(timestamp: oldTurn), mtime: now, process: resumed)?.status, .idle)
        XCTAssertEqual(decide(.toolCallPending(timestamp: oldTurn, waitsForUser: false), mtime: now,
                              process: resumed)?.status, .idle)
        // Ein neuer Turn nach dem Resume arbeitet wieder.
        XCTAssertEqual(decide(.userMessage(timestamp: now.addingTimeInterval(-5)), mtime: now.addingTimeInterval(-5),
                              process: resumed)?.status, .working)
    }

    func testTurnRightAtProcessStartCountsAsThisRun() {
        // `task_started` eines mit Prompt gestarteten Codex kann wegen
        // Rundung minimal vor der gemessenen Startzeit liegen.
        let process = CodexProcessLiveness.running(since: turnStart.addingTimeInterval(1))
        XCTAssertEqual(decide(.userMessage(timestamp: turnStart), mtime: silentMTime, process: process)?.status, .working)
    }

    func testHungProcessFallsBackToIdleAfterTheUpperLimit() {
        let quiet = now.addingTimeInterval(-(AgentTranscriptStatusDecider.codexOpenTurnStallSeconds + 1))
        XCTAssertEqual(decide(.assistantMessageOngoing(timestamp: quiet), mtime: quiet,
                              process: .running(since: quiet.addingTimeInterval(-60)))?.status, .idle)
    }

    func testUnreadableStartTimeFallsBackToTwoMinuteLimit() {
        XCTAssertEqual(decide(.assistantMessageOngoing(timestamp: turnStart), mtime: silentMTime,
                              process: .running(since: nil))?.status, .idle)
        XCTAssertEqual(decide(.assistantMessageOngoing(timestamp: turnStart), mtime: now.addingTimeInterval(-10),
                              process: .running(since: nil))?.status, .working)
    }

    func testClaudeDefaultIsUnchanged() {
        // Claude-Aufrufer geben kein Prozesswissen mit: 120-s-Sicherung wie bisher.
        let stale = now.addingTimeInterval(-(AgentTranscriptStatusDecider.workingStallSeconds + 5))
        let decision = AgentTranscriptStatusDecider.decide(
            lastEvent: .assistantMessageOngoing(timestamp: stale), fileMTime: stale, now: now, priorTurnFinishedAt: nil)
        XCTAssertEqual(decision?.status, .idle)
    }

    // MARK: - Prozesswissen

    func testLivenessOfOwnProcessAndOfAMissingPID() throws {
        guard case .running(let since) = CodexProcessLiveness.of(pid: getpid()) else {
            return XCTFail("eigener Prozess lebt")
        }
        XCTAssertNotNil(since)
        XCTAssertEqual(CodexProcessLiveness.of(pid: nil), .unknown)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(CodexProcessLiveness.of(pid: process.processIdentifier), .notRunning)
    }

    func testProcessIndexLookup() {
        let chat = UUID()
        let start = now.addingTimeInterval(-60)
        XCTAssertEqual(CodexProcessLiveness.of(sessionID: chat, index: nil), .unknown)
        XCTAssertEqual(CodexProcessLiveness.of(sessionID: chat, index: [:]), .notRunning)
        XCTAssertEqual(CodexProcessLiveness.of(sessionID: chat, index: [chat: start]), .running(since: start))
    }

    func testProcessIndexKeepsTheNewestRunPerChat() {
        let chat = UUID()
        let old = now.addingTimeInterval(-600), new = now.addingTimeInterval(-5)
        XCTAssertEqual(CodexChatProcessIndex.index([(chat, new), (chat, old)])[chat], new)
        XCTAssertEqual(CodexChatProcessIndex.index([(chat, old), (chat, new)])[chat], new)
    }

    func testSessionIDFromEnvironment() {
        let chat = UUID()
        XCTAssertEqual(CodexChatProcessIndex.sessionID(inEnvironment: [
            "PATH=/bin", "WHISPERM8_SESSION_ID=\(chat.uuidString)", "HOME=/h",
        ]), chat)
        XCTAssertNil(CodexChatProcessIndex.sessionID(inEnvironment: ["WHISPERM8_SESSION_ID_X=1", "HOME=/h"]))
        XCTAssertNil(CodexChatProcessIndex.sessionID(inEnvironment: ["WHISPERM8_SESSION_ID=kaputt"]))
    }

    func testParseProcEnvironmentSkipsPathAndArguments() {
        // argc=2, Programmpfad, Füll-Nullen, argv[0..1], Umgebung, Abschluss.
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(2).littleEndian) { bytes.append(contentsOf: $0) }
        for part in ["/opt/codex", "", "", "codex", "resume"] { bytes += Array(part.utf8) + [0] }
        for part in ["A=1", "WHISPERM8_SESSION_ID=x"] { bytes += Array(part.utf8) + [0] }
        bytes += [0, 0]
        XCTAssertEqual(CodexChatProcessIndex.parseProcEnvironment(bytes), ["A=1", "WHISPERM8_SESSION_ID=x"])
        XCTAssertEqual(CodexChatProcessIndex.parseProcEnvironment([1, 0]), [])
    }

    func testProcessIndexFindsAChildWithTheChatIDInItsEnvironment() throws {
        // Echter Scan: ein Prozess namens „codex“ mit Chat-ID in der Umgebung.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-liveness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let binary = dir.appendingPathComponent("codex")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: binary)
        let chat = UUID()
        let process = Process()
        process.executableURL = binary
        process.arguments = ["30"]
        process.environment = ["WHISPERM8_SESSION_ID": chat.uuidString]
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }

        let index = CodexChatProcessIndex.scan()
        XCTAssertNotNil(index)
        guard case .running(let since) = CodexProcessLiveness.of(sessionID: chat, index: index) else {
            return XCTFail("Codex-Prozess des Chats nicht gefunden")
        }
        XCTAssertNotNil(since)
        XCTAssertEqual(CodexProcessLiveness.of(sessionID: UUID(), index: index), .notRunning)
    }
}

// MARK: - CLI-Probe (derive mit Temp-Rollout)

final class CodexOpenTurnProbeTests: XCTestCase {
    private var tempDir: URL!
    private var savedLiveness: ((AgentChatSession, Date) -> CodexProcessLiveness)!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-probe-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        savedLiveness = ChatsStatusProbe.codexLiveness
    }

    override func tearDown() {
        ChatsStatusProbe.codexLiveness = savedLiveness
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func rollout(turnAt: Date, mtime: Date) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: turnAt)
        let lines = [
            #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"task_started","turn_id":"t"}}"#,
            #"{"timestamp":"\#(stamp)","type":"response_item","payload":{"type":"reasoning","id":"rs"}}"#,
        ]
        let url = tempDir.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    private func codexChat() -> AgentChatSession {
        AgentChatSession(provider: .codex, projectID: UUID(), title: "codex")
    }

    func testLiveProcessKeepsALongAnswerWorkingInTheCLI() throws {
        let now = Date()
        let url = try rollout(turnAt: now.addingTimeInterval(-300), mtime: now.addingTimeInterval(-286))
        ChatsStatusProbe.codexLiveness = { _, _ in .running(since: now.addingTimeInterval(-600)) }
        let info = ChatsStatusProbe.derive(from: url, provider: .codex, session: codexChat(),
                                           source: "transcriptEstimate", now: now)
        XCTAssertEqual(info.status, .working)
    }

    func testChatWithoutProcessIsNotWorkingInTheCLI() throws {
        let now = Date()
        // Auch bei frischer Datei: kein Prozess, keine Arbeit.
        let url = try rollout(turnAt: now.addingTimeInterval(-5), mtime: now.addingTimeInterval(-5))
        ChatsStatusProbe.codexLiveness = { _, _ in .notRunning }
        let info = ChatsStatusProbe.derive(from: url, provider: .codex, session: codexChat(),
                                           source: "transcriptEstimate", now: now)
        XCTAssertEqual(info.status, .idle)
    }

    func testOldRolloutWithOpenTurnAfterCrashIsNotWorkingInTheCLI() throws {
        let now = Date()
        let url = try rollout(turnAt: now.addingTimeInterval(-3 * 3600), mtime: now.addingTimeInterval(-3))
        ChatsStatusProbe.codexLiveness = { _, _ in .running(since: now.addingTimeInterval(-30)) }
        let info = ChatsStatusProbe.derive(from: url, provider: .codex, session: codexChat(),
                                           source: "transcriptEstimate", now: now)
        XCTAssertEqual(info.status, .idle)
    }

    func testUnknownProcessKeepsTheStatFastPath() throws {
        let now = Date()
        let url = try rollout(turnAt: now.addingTimeInterval(-300), mtime: now.addingTimeInterval(-286))
        ChatsStatusProbe.codexLiveness = { _, _ in .unknown }
        let info = ChatsStatusProbe.derive(from: url, provider: .codex, session: codexChat(),
                                           source: "transcriptEstimate", now: now)
        XCTAssertEqual(info.status, .idle)
    }

    func testOnlyCodexChatsAskForTheProcess() {
        // Claude und Codex-Subagent-Jobs (tragen keine Chat-ID) bleiben ohne
        // Prozesswissen — der Default-Weg scannt für sie nicht.
        let claude = AgentChatSession(provider: .claude, projectID: UUID(), title: "c")
        XCTAssertEqual(savedLiveness(claude, Date()), .unknown)
        var job = codexChat()
        job.kind = .subagentJob
        XCTAssertEqual(savedLiveness(job, Date()), .unknown)
    }
}

// MARK: - App-Watcher

final class CodexOpenTurnWatcherTests: XCTestCase {
    func testPollSnapshotPassesTheProcessToTheDecider() {
        let now = Date()
        let url = URL(fileURLWithPath: "/tmp/whisperm8-codex-open-turn.jsonl")
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-300))
        let tail = #"{"timestamp":"\#(stamp)","type":"response_item","payload":{"type":"reasoning","id":"rs"}}"#
        let entry = WatchedSession(id: UUID(), provider: .codex, cwd: "/tmp", externalSessionID: "x",
                                   transcriptURL: url, lastTurnFinishedAt: nil)
        let stat = AgentTranscriptFileStat(mtime: now.addingTimeInterval(-286), size: 10)
        func poll(_ process: CodexProcessLiveness) -> AgentSessionRuntimeStatus? {
            AgentSessionRuntimeWatcher.pollSnapshot(
                for: entry, now: now,
                statProvider: { _ in stat }, tailProvider: { _, _ in tail }, urlResolver: { _ in url },
                codexProcess: process
            ).decision?.status
        }
        XCTAssertEqual(poll(.running(since: now.addingTimeInterval(-600))), .working)
        XCTAssertEqual(poll(.notRunning), .idle)
        XCTAssertEqual(poll(.unknown), .idle)
    }
}
