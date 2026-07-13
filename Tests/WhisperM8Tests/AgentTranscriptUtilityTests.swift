import Foundation
import XCTest
@testable import WhisperM8

final class AgentTranscriptUtilityTests: XCTestCase {
    // MARK: - Transcript Locator

    func testClaudeCwdEncodingMatchesActualEncoding() {
        // Claude ersetzt jeden Nicht-Alphanumerik-Char durch `-`.
        XCTAssertEqual(
            AgentTranscriptLocator.encodeClaudeCwd("/Users/foo/repos/heartbeat"),
            "-Users-foo-repos-heartbeat"
        )
        XCTAssertEqual(
            AgentTranscriptLocator.encodeClaudeCwd("/var/lib/data_2"),
            "-var-lib-data-2"
        )
    }

    func testLocateClaudeFindsTranscriptAcrossRoots() throws {
        // Multi-Account: das Transcript liegt im ZWEITEN Root (Profil) —
        // der deterministische Lookup muss über alle Roots laufen.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocatorMultiRoot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let mainRoot = base.appendingPathComponent("main-projects", isDirectory: true)
        let profileRoot = base.appendingPathComponent("profile-projects", isDirectory: true)
        let cwd = "/Users/foo/repos/heartbeat"
        let encoded = AgentTranscriptLocator.encodeClaudeCwd(cwd)
        let transcript = profileRoot
            .appendingPathComponent(encoded, isDirectory: true)
            .appendingPathComponent("session-1.jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: transcript)

        let found = AgentTranscriptLocator.locateClaude(
            externalSessionID: "session-1",
            cwd: cwd,
            roots: [mainRoot, profileRoot]
        )
        XCTAssertEqual(found?.path, transcript.path)
    }

    func testLocateClaudeFallsBackToSessionIDGlobWhenEncodingMismatches() throws {
        // Verteidigungslinie: die JSONL liegt in einem Projekt-Ordner, dessen
        // Name NICHT dem erwarteten encoded-cwd entspricht (Encoding-Änderung
        // durch Claude oder umbenannter/verschobener Projekt-Ordner). Die
        // eindeutige Session-ID muss die Datei trotzdem finden.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocatorGlobFallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("projects", isDirectory: true)
        let transcript = root
            .appendingPathComponent("ganz-anderer-ordnername", isDirectory: true)
            .appendingPathComponent("aaaa1111-2222-3333-4444-555566667777.jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Kopf traegt den erwarteten cwd — nur dann darf der Fallback greifen.
        try Data(#"{"type":"user","cwd":"/Users/foo/repos/heartbeat"}"#.utf8 + Data("\n".utf8))
            .write(to: transcript)

        let found = AgentTranscriptLocator.locateClaude(
            externalSessionID: "aaaa1111-2222-3333-4444-555566667777",
            cwd: "/Users/foo/repos/heartbeat",
            roots: [root]
        )
        // `resolvingSymlinksInPath`: contentsOfDirectory liefert /private/var,
        // temporaryDirectory /var — dieselbe Datei.
        XCTAssertEqual(
            found?.resolvingSymlinksInPath().path,
            transcript.resolvingSymlinksInPath().path
        )

        // Nicht existierende Session bleibt nil — der Fallback erfindet nichts.
        XCTAssertNil(AgentTranscriptLocator.locateClaude(
            externalSessionID: "ffff0000-0000-0000-0000-000000000000",
            cwd: "/Users/foo/repos/heartbeat",
            roots: [root]
        ))

        // Fremder cwd im Kopf → Kandidat wird VERWORFEN (kein falscher Chat).
        XCTAssertNil(AgentTranscriptLocator.locateClaude(
            externalSessionID: "aaaa1111-2222-3333-4444-555566667777",
            cwd: "/Users/foo/repos/GANZ-ANDERES-PROJEKT",
            roots: [root]
        ))
    }

    // MARK: - Terminal drag-drop payload

    func testTerminalDropPayloadEscapesNothingForSimplePath() {
        XCTAssertEqual(
            TerminalDropPayload.build(from: ["/Users/me/repos/whisperm8/file.md"]),
            "/Users/me/repos/whisperm8/file.md"
        )
    }

    func testTerminalDropPayloadEscapesSpacesAndSpecialChars() {
        XCTAssertEqual(
            TerminalDropPayload.shellEscape("/Users/me/Tim AI/2026-05-11 plan.md"),
            "/Users/me/Tim\\ AI/2026-05-11\\ plan.md"
        )
    }

    func testTerminalDropPayloadEscapesUmlauts() {
        // Umlaute sind nicht im "safe"-Set, müssen also escapt werden, damit
        // die Shell sie nicht als Argument-Trennzeichen oder Glob behandelt.
        let escaped = TerminalDropPayload.shellEscape("/Users/me/Übersicht.md")
        XCTAssertTrue(escaped.contains("\\Ü"))
    }

    func testTerminalDropPayloadJoinsMultiplePathsWithSpaces() {
        let result = TerminalDropPayload.build(from: [
            "/tmp/a.md",
            "/tmp/b c.md"
        ])
        XCTAssertEqual(result, "/tmp/a.md /tmp/b\\ c.md")
    }

    func testTerminalDropPayloadEmptyInput() {
        XCTAssertEqual(TerminalDropPayload.build(from: []), "")
    }

    // MARK: - Summary excerpt + parser
}
