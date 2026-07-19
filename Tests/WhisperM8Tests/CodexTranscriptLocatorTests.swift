import Foundation
import XCTest
@testable import WhisperM8

/// Tests fuer die zentrale Codex-Session-ID→URL-Aufloesung (C16):
/// Hit, Miss (Negativ-Cache), Move-Invalidierung und Dateinamen-Parsing.
/// Der Cache ist prozessweit — jeder Test resettet ihn und nutzt eigene
/// Roots/UUIDs.
final class CodexTranscriptLocatorTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        CodexTranscriptLocator.resetForTesting()
        CodexTranscriptLocator.negativeTTL = 2
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm8-codex-locator-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        CodexTranscriptLocator.resetForTesting()
        CodexTranscriptLocator.negativeTTL = 2
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    /// Kanonischer Pfad fuer Vergleiche: der Enumerator liefert
    /// /private/var-Pfade, temporaryDirectory den /var-Symlink.
    private func canonical(_ url: URL?) -> String? {
        url?.resolvingSymlinksInPath().path
    }

    /// Legt `<root>/<datePath>/rollout-<stamp>-<id>.jsonl` an.
    @discardableResult
    private func makeRollout(id: String, datePath: String = "2026/07/19") throws -> URL {
        let dir = root.appendingPathComponent(datePath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rollout-2026-07-19T10-00-00-\(id).jsonl")
        try Data("{}\n".utf8).write(to: url)
        return url
    }

    func testFindsSessionByID() throws {
        let id = UUID().uuidString.lowercased()
        let expected = try makeRollout(id: id)
        XCTAssertEqual(canonical(CodexTranscriptLocator.url(forSessionID: id, root: root)), canonical(expected))
    }

    func testOneScanHarvestsAllSessions() throws {
        let a = UUID().uuidString.lowercased()
        let b = UUID().uuidString.lowercased()
        let urlA = try makeRollout(id: a, datePath: "2026/07/18")
        let urlB = try makeRollout(id: b, datePath: "2026/07/19")

        XCTAssertEqual(canonical(CodexTranscriptLocator.url(forSessionID: a, root: root)), canonical(urlA))
        // Zweiter Lookup ist ein Hit aus dem Harvest — auch wenn wir das
        // Root-Verzeichnis wegdrehen, wird B noch gefunden (kein Re-Scan).
        let goneRoot = root.appendingPathComponent("gone", isDirectory: true)
        XCTAssertEqual(canonical(CodexTranscriptLocator.url(forSessionID: b, root: goneRoot)), canonical(urlB))
    }

    func testMissIsNegativelyCachedUntilTTLExpires() throws {
        let id = UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        XCTAssertNil(CodexTranscriptLocator.url(forSessionID: id, root: root))

        // Datei entsteht NACH dem Miss: innerhalb der TTL bleibt der
        // Negativ-Cache aktiv …
        let url = try makeRollout(id: id)
        XCTAssertNil(CodexTranscriptLocator.url(forSessionID: id, root: root),
                     "Negativ-Cache unterdrueckt den Re-Scan innerhalb der TTL")

        // … nach Ablauf wird neu gescannt und gefunden.
        CodexTranscriptLocator.resetForTesting()
        CodexTranscriptLocator.negativeTTL = 0
        XCTAssertNil(CodexTranscriptLocator.url(forSessionID: UUID().uuidString, root: root),
                     "anderer Miss ist unabhaengig")
        XCTAssertEqual(canonical(CodexTranscriptLocator.url(forSessionID: id, root: root)), canonical(url))
    }

    func testMovedFileIsReResolved() throws {
        let id = UUID().uuidString.lowercased()
        let original = try makeRollout(id: id, datePath: "2026/07/18")
        XCTAssertEqual(canonical(CodexTranscriptLocator.url(forSessionID: id, root: root)), canonical(original))

        // Datei "wandert" (z. B. manuelles Aufraeumen): Hit-Validierung
        // erkennt den toten Pfad und der Re-Scan findet den neuen.
        let newDir = root.appendingPathComponent("2026/07/19", isDirectory: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        let moved = newDir.appendingPathComponent(original.lastPathComponent)
        try FileManager.default.moveItem(at: original, to: moved)

        XCTAssertEqual(canonical(CodexTranscriptLocator.url(forSessionID: id, root: root)), canonical(moved))
    }

    func testNonUUIDSessionIDFallsBackToSuffixMatch() throws {
        let dir = root.appendingPathComponent("2026/07/19", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rollout-2026-07-19T10-00-00-custom-id-42.jsonl")
        try Data("{}\n".utf8).write(to: url)

        XCTAssertEqual(canonical(CodexTranscriptLocator.url(forSessionID: "custom-id-42", root: root)), canonical(url),
                       "Nicht-UUID-IDs behalten den alten Suffix-Match")
    }

    func testSessionIDParsing() {
        let id = "0d5eae2e-7a41-4be1-9b1a-8c5f2f3a4b5c"
        XCTAssertEqual(
            CodexTranscriptLocator.sessionID(fromFilename: "rollout-2026-07-19T10-00-00-\(id).jsonl"),
            id
        )
        XCTAssertEqual(
            CodexTranscriptLocator.sessionID(fromFilename: "rollout-x-\(id.uppercased()).jsonl"),
            id, "UUIDs werden lowercased normalisiert"
        )
        XCTAssertNil(CodexTranscriptLocator.sessionID(fromFilename: "rollout-kein-uuid.jsonl"))
        XCTAssertNil(CodexTranscriptLocator.sessionID(fromFilename: "\(id).jsonl"),
                     "ohne '-'-Trenner vor der UUID kein Match")
        XCTAssertNil(CodexTranscriptLocator.sessionID(fromFilename: "rollout-\(id).txt"))
    }
}
