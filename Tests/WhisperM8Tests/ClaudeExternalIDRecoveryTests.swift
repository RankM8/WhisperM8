import XCTest
@testable import WhisperM8

/// Selbstheilung kaputter Claude-Bindings aus dem Hook-Event-File
/// (Vorfall 2026-09-30, Chat 06760440).
final class ClaudeExternalIDRecoveryTests: XCTestCase {
    private func line(_ event: String, _ id: String, extra: String = "") -> String {
        #"{"session_id":"\#(id)","transcript_path":"/t/\#(id).jsonl","hook_event_name":"\#(event)"\#(extra)}"#
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

    func testRecoversLastSessionWithTurnAndExistingTranscript() {
        let recovered = ClaudeExternalIDRecovery.recoverableSessionID(
            eventLines: incidentLines.map { Substring($0) },
            brokenID: "8a5a7119",
            transcriptExists: { $0 == "/t/ac020fd4.jsonl" || $0 == "/t/08793d2e.jsonl" })
        XCTAssertEqual(recovered, "ac020fd4", "Fork ohne Turn zählt nicht, nur der echte Verlauf")
    }

    func testPrefersNewestTurnAndSkipsMissingFiles() {
        let lines = [line("Stop", "a"), line("Stop", "b"), line("UserPromptSubmit", "c")]
        let recovered = ClaudeExternalIDRecovery.recoverableSessionID(
            eventLines: lines.map { Substring($0) },
            brokenID: "kaputt",
            transcriptExists: { $0 != "/t/c.jsonl" })
        XCTAssertEqual(recovered, "b", "c ist jünger, hat aber keine Datei mehr")
    }

    func testNoRecoveryWithoutCandidate() {
        let recovered = ClaudeExternalIDRecovery.recoverableSessionID(
            eventLines: incidentLines.map { Substring($0) },
            brokenID: "8a5a7119",
            transcriptExists: { _ in false })
        XCTAssertNil(recovered)
    }

    func testReadsEventFileFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("echt.jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        let eventFile = dir.appendingPathComponent("events.jsonl")
        let content = [
            #"{"session_id":"echt","transcript_path":"\#(transcript.path)","hook_event_name":"Stop"}"#,
            #"{"session_id":"leer","transcript_path":"\#(dir.path)/leer.jsonl","hook_event_name":"SessionStart"}"#,
            "",
        ].joined(separator: "\n")
        try Data(content.utf8).write(to: eventFile)

        XCTAssertEqual(
            ClaudeExternalIDRecovery.recoverableSessionID(eventFileURL: eventFile, brokenID: "leer"),
            "echt")
    }
}
