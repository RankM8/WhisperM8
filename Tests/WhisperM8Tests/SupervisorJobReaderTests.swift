import Foundation
import XCTest
@testable import WhisperM8

final class SupervisorJobReaderTests: XCTestCase {

    // MARK: - parse

    func testParseExtractsCoreFields() {
        let json = """
        {
          "name": "background agent build diagnostics",
          "intent": "diagnose",
          "cwd": "/Users/x/repos/whisperm8/.claude/worktrees/bg-agents-phase-1",
          "state": "done",
          "linkScanPath": "/Users/x/.claude/projects/encoded/07535129.jsonl",
          "updatedAt": "2026-05-12T20:33:15.544Z",
          "daemonShort": "07535129"
        }
        """
        let state = SupervisorJobReader.parse(data: Data(json.utf8), shortIDFallback: "07535129")
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.shortID, "07535129")
        XCTAssertEqual(state?.name, "background agent build diagnostics")
        XCTAssertEqual(state?.intent, "diagnose")
        XCTAssertEqual(state?.cwd, "/Users/x/repos/whisperm8/.claude/worktrees/bg-agents-phase-1")
        XCTAssertEqual(state?.state, "done")
        XCTAssertEqual(state?.linkScanPath, "/Users/x/.claude/projects/encoded/07535129.jsonl")
        XCTAssertNotNil(state?.updatedAt)
    }

    func testParseUsesDirectoryNameAsShortIDFallback() {
        let json = """
        { "cwd": "/tmp/x" }
        """
        let state = SupervisorJobReader.parse(data: Data(json.utf8), shortIDFallback: "abc12345")
        XCTAssertEqual(state?.shortID, "abc12345")
    }

    func testParseReturnsNilWhenCwdMissing() {
        let json = """
        { "name": "x", "daemonShort": "abc12345" }
        """
        XCTAssertNil(SupervisorJobReader.parse(data: Data(json.utf8), shortIDFallback: "abc12345"))
    }

    func testParseReturnsNilForGarbage() {
        XCTAssertNil(SupervisorJobReader.parse(data: Data("not json".utf8), shortIDFallback: "x"))
    }

    func testParseTreatsEmptyStringsAsNil() {
        let json = """
        {
          "cwd": "/tmp/x",
          "name": "  ",
          "intent": "",
          "state": "",
          "linkScanPath": ""
        }
        """
        let state = SupervisorJobReader.parse(data: Data(json.utf8), shortIDFallback: "x")
        XCTAssertNotNil(state)
        XCTAssertNil(state?.name)
        XCTAssertNil(state?.intent)
        XCTAssertNil(state?.state)
        XCTAssertNil(state?.linkScanPath)
    }

    // MARK: - parseISODate

    func testParseISODateAcceptsFractionalAndPlainISO() {
        XCTAssertNotNil(SupervisorJobReader.parseISODate("2026-05-12T20:33:15.544Z"))
        XCTAssertNotNil(SupervisorJobReader.parseISODate("2026-05-12T20:33:15Z"))
        XCTAssertNil(SupervisorJobReader.parseISODate(nil))
        XCTAssertNil(SupervisorJobReader.parseISODate(""))
        XCTAssertNil(SupervisorJobReader.parseISODate("not a date"))
    }

    // MARK: - readAll smoke

    func testReadAllReturnsEmptyForNonexistentDirectory() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString)")
        XCTAssertEqual(SupervisorJobReader.readAll(from: url), [])
    }

    func testReadAllParsesValidJobsAndSkipsBroken() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jobs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Job 1: valide
        let job1 = root.appendingPathComponent("ok11111", isDirectory: true)
        try FileManager.default.createDirectory(at: job1, withIntermediateDirectories: true)
        try """
        {"cwd": "/tmp/a", "name": "alpha", "daemonShort": "ok11111"}
        """.write(to: job1.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)

        // Job 2: kaputt
        let job2 = root.appendingPathComponent("bad22222", isDirectory: true)
        try FileManager.default.createDirectory(at: job2, withIntermediateDirectories: true)
        try "not json".write(to: job2.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)

        // File pins.json (kein Job-Directory) — wird ueberlesen
        try "{}".write(to: root.appendingPathComponent("pins.json"), atomically: true, encoding: .utf8)

        let jobs = SupervisorJobReader.readAll(from: root)
        XCTAssertEqual(jobs.map(\.shortID), ["ok11111"])
        XCTAssertEqual(jobs.first?.name, "alpha")
    }

    // MARK: - mostRecentlyActive

    func testMostRecentlyActiveReturnsJobWithLatestLinkScanMtime() {
        let now = Date()
        let jobs = [
            SupervisorJobState(shortID: "a", name: "A", intent: nil, cwd: "/x", state: "done", linkScanPath: "/jsonl/a", updatedAt: nil),
            SupervisorJobState(shortID: "b", name: "B", intent: nil, cwd: "/y", state: "working", linkScanPath: "/jsonl/b", updatedAt: nil),
            SupervisorJobState(shortID: "c", name: "C", intent: nil, cwd: "/z", state: "done", linkScanPath: "/jsonl/c", updatedAt: nil)
        ]
        let mtimes: [String: Date] = [
            "/jsonl/a": now.addingTimeInterval(-50),
            "/jsonl/b": now.addingTimeInterval(-5),   // ← youngest
            "/jsonl/c": now.addingTimeInterval(-30)
        ]
        let active = SupervisorJobReader.mostRecentlyActive(
            among: jobs,
            within: 120,
            now: now,
            modificationDate: { mtimes[$0.path] }
        )
        XCTAssertEqual(active?.shortID, "b")
    }

    func testMostRecentlyActiveFiltersByRecencyWindow() {
        let now = Date()
        let jobs = [
            SupervisorJobState(shortID: "old", name: nil, intent: nil, cwd: "/x", state: nil, linkScanPath: "/jsonl/old", updatedAt: nil)
        ]
        let mtimes: [String: Date] = ["/jsonl/old": now.addingTimeInterval(-3600)] // 1 hour ago
        let active = SupervisorJobReader.mostRecentlyActive(
            among: jobs,
            within: 60,
            now: now,
            modificationDate: { mtimes[$0.path] }
        )
        XCTAssertNil(active, "Sessions outside the recency window must be ignored")
    }

    func testMostRecentlyActiveFallsBackToUpdatedAtWhenLinkScanMissing() {
        let now = Date()
        let recentUpdate = now.addingTimeInterval(-10)
        let jobs = [
            SupervisorJobState(shortID: "noLink", name: "N", intent: nil, cwd: "/x", state: nil, linkScanPath: nil, updatedAt: recentUpdate)
        ]
        let active = SupervisorJobReader.mostRecentlyActive(
            among: jobs,
            within: 60,
            now: now,
            modificationDate: { _ in nil }
        )
        XCTAssertEqual(active?.shortID, "noLink")
    }

    func testMostRecentlyActiveReturnsNilForEmptyInput() {
        XCTAssertNil(SupervisorJobReader.mostRecentlyActive(
            among: [], within: 60, now: Date(), modificationDate: { _ in nil }
        ))
    }
}
