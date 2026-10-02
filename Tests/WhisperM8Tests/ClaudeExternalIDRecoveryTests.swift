import XCTest
@testable import WhisperM8

/// Selbstheilung kaputter Claude-Bindings aus dem Hook-Event-File
/// (Vorfall 2026-09-30, Chat 06760440).
final class ClaudeExternalIDRecoveryTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func line(_ event: String, _ id: String, path: String? = nil, extra: String = "") -> String {
        #"{"session_id":"\#(id)","transcript_path":"\#(path ?? "/t/\(id).jsonl")","hook_event_name":"\#(event)"\#(extra)}"#
    }

    /// Event-Folge des Vorfalls: Turns nur auf ac020fd4, danach bg-Fork,
    /// leere Startup-Session und SessionEnds.
    private var incidentLines: [String] {
        [
            line("SessionStart", "ac020fd4", extra: #","source":"resume""#),
            line("UserPromptSubmit", "ac020fd4"),
            line("PreToolUse", "ac020fd4", extra: #","tool_response":"AAAA""#),
            line("Stop", "ac020fd4"),
            line("SessionStart", "08793d2e", extra: #","source":"fork""#),
            line("SessionStart", "8a5a7119", extra: #","source":"startup""#),
            line("SessionEnd", "8a5a7119"),
            line("SessionEnd", "ac020fd4"),
        ]
    }

    private func existingPaths(_ paths: Set<String>) -> (String, String) -> URL? {
        { _, logged in paths.contains(logged) ? URL(fileURLWithPath: logged) : nil }
    }

    func testRecoversLastSessionWithTurnAndExistingTranscript() {
        let candidate = ClaudeExternalIDRecovery.recoverableCandidate(
            eventLines: incidentLines.map { Substring($0) },
            brokenID: "8a5a7119",
            locateTranscript: existingPaths(["/t/ac020fd4.jsonl", "/t/08793d2e.jsonl"]))
        XCTAssertEqual(candidate?.sessionID, "ac020fd4", "Fork ohne Turn zählt nicht, nur der echte Verlauf")
    }

    /// Review 2026-10-02: Der bg-Fork schreibt seine Turns ins selbe
    /// Event-File und ist jünger als das Original — er darf nie gewählt werden.
    func testSkipsBackgroundForkEvenWithNewerTurns() {
        let lines = incidentLines + [
            line("UserPromptSubmit", "08793d2e"),
            line("Stop", "08793d2e"),
        ]
        let candidate = ClaudeExternalIDRecovery.recoverableCandidate(
            eventLines: lines.map { Substring($0) },
            brokenID: "8a5a7119",
            locateTranscript: existingPaths(["/t/ac020fd4.jsonl", "/t/08793d2e.jsonl"]))
        XCTAssertEqual(candidate?.sessionID, "ac020fd4")
    }

    func testPrefersNewestTurnAndSkipsMissingFiles() {
        let lines = [line("Stop", "a"), line("Stop", "b"), line("UserPromptSubmit", "c")]
        let candidate = ClaudeExternalIDRecovery.recoverableCandidate(
            eventLines: lines.map { Substring($0) },
            brokenID: "kaputt",
            locateTranscript: existingPaths(["/t/a.jsonl", "/t/b.jsonl"]))
        XCTAssertEqual(candidate?.sessionID, "b", "c ist jünger, hat aber keine Datei mehr")
    }

    func testNoRecoveryWithoutCandidate() {
        let candidate = ClaudeExternalIDRecovery.recoverableCandidate(
            eventLines: incidentLines.map { Substring($0) },
            brokenID: "8a5a7119",
            locateTranscript: { _, _ in nil })
        XCTAssertNil(candidate)
    }

    /// Vorfall 2026-10-01: Das Hook-Event protokolliert den Pfad unter
    /// RankM8, ein Kontowechsel hat die Datei aber nach PowerUser2
    /// verschoben. Der Default-Locator muss sie über die Profil-Roots finden.
    func testFindsTranscriptMovedToAnotherProfileByAccountMove() throws {
        let projectPath = "/Users/tester/repos/heartbeat"
        let encoded = AgentTranscriptLocator.encodeClaudeCwd(projectPath)
        let oldRoot = tempDir.appendingPathComponent(".claude-profiles/RankM8/projects", isDirectory: true)
        let newRoot = tempDir.appendingPathComponent(".claude-profiles/PowerUser2/projects", isDirectory: true)
        let movedDir = newRoot.appendingPathComponent(encoded, isDirectory: true)
        try FileManager.default.createDirectory(at: movedDir, withIntermediateDirectories: true)
        let moved = movedDir.appendingPathComponent("ac020fd4.jsonl")
        try Data("{}\n".utf8).write(to: moved)
        let loggedPath = oldRoot.appendingPathComponent(encoded).appendingPathComponent("ac020fd4.jsonl").path

        let candidate = ClaudeExternalIDRecovery.recoverableCandidate(
            eventLines: [line("Stop", "ac020fd4", path: loggedPath)].map { Substring($0) },
            brokenID: "8a5a7119",
            locateTranscript: { id, logged in
                if FileManager.default.fileExists(atPath: logged) { return URL(fileURLWithPath: logged) }
                return AgentTranscriptLocator.locateClaude(
                    externalSessionID: id, cwd: projectPath, roots: [oldRoot, newRoot])
            })

        XCTAssertEqual(candidate?.sessionID, "ac020fd4")
        XCTAssertEqual(candidate?.transcriptURL.standardizedFileURL.path, moved.standardizedFileURL.path)
        XCTAssertEqual(
            ClaudeAccountProfiles.profileName(forTranscriptPath: candidate?.transcriptURL.path ?? ""),
            "PowerUser2", "Profil des Chats muss dorthin mitziehen, wo die Datei heute liegt")
    }

    // MARK: recoveries(…) — Event-File auf Disk

    private func writeEventFile(for localID: UUID, lines: [String]) throws -> ClaudeHookPaths {
        let paths = ClaudeHookPaths(rootDirectory: tempDir)
        try FileManager.default.createDirectory(at: paths.eventsDirectory, withIntermediateDirectories: true)
        try Data((lines + [""]).joined(separator: "\n").utf8)
            .write(to: paths.eventFileURL(localSessionID: localID))
        return paths
    }

    private func brokenSession() -> AgentChatSession {
        AgentChatSession(provider: .claude, projectID: UUID(), externalSessionID: "8a5a7119",
                         title: "kaputt", claudeProfileName: "RankM8")
    }

    func testRecoveryCarriesProfileOfCurrentTranscriptLocation() throws {
        let session = brokenSession()
        let paths = try writeEventFile(for: session.id, lines: incidentLines)
        let recoveries = ClaudeExternalIDRecovery.recoveries(
            candidates: [session],
            projectPathByID: [session.projectID: "/p"],
            boundExternalIDs: ["8a5a7119"],
            hookPaths: paths,
            locateTranscript: { id, _ in
                id == "ac020fd4"
                    ? URL(fileURLWithPath: "/Users/x/.claude-profiles/PowerUser2/projects/-p/ac020fd4.jsonl")
                    : nil
            })
        XCTAssertEqual(recoveries, [.init(localID: session.id, brokenID: "8a5a7119",
                                          recoveredID: "ac020fd4", expectedProfileName: "RankM8",
                                          recoveredProfileName: "PowerUser2")],
                       "Profil beim Scan wird mitgeführt — angewendet nur, wenn es noch gilt")
    }

    /// Lebt der Verlauf schon in einem anderen Chat weiter (Ersatz-Chat
    /// cfe6b1d0), wird nicht geheilt — sonst teilten sich zwei Chats eine
    /// Claude-Session.
    func testNoRecoveryWhenCandidateIsBoundToAnotherChat() throws {
        let session = brokenSession()
        let paths = try writeEventFile(for: session.id, lines: incidentLines)
        let recoveries = ClaudeExternalIDRecovery.recoveries(
            candidates: [session],
            projectPathByID: [session.projectID: "/p"],
            boundExternalIDs: ["8a5a7119", "ac020fd4"],
            hookPaths: paths,
            locateTranscript: { _, _ in URL(fileURLWithPath: "/Users/x/.claude/projects/-p/ac020fd4.jsonl") })
        XCTAssertTrue(recoveries.isEmpty)
    }

    func testReadsEventFileFromDisk() throws {
        let transcript = tempDir.appendingPathComponent("echt.jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        let eventFile = tempDir.appendingPathComponent("events.jsonl")
        let content = [
            #"{"session_id":"echt","transcript_path":"\#(transcript.path)","hook_event_name":"Stop"}"#,
            #"{"session_id":"leer","transcript_path":"\#(tempDir.path)/leer.jsonl","hook_event_name":"SessionStart"}"#,
            "",
        ].joined(separator: "\n")
        try Data(content.utf8).write(to: eventFile)

        XCTAssertEqual(
            ClaudeExternalIDRecovery.recoverableCandidate(
                eventFileURL: eventFile, brokenID: "leer", projectPath: tempDir.path)?.sessionID,
            "echt")
    }
}
