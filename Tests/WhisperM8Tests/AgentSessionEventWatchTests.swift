import Foundation
import XCTest
@testable import WhisperM8

// MARK: - FileEventSource (P2 S2)

@MainActor
final class FileEventSourceTests: XCTestCase {
    private func makeTempFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileEventSourceTests-\(UUID().uuidString).jsonl")
        try Data("zeile-1\n".utf8).write(to: url)
        return url
    }

    func testWriteFiresOnChange() async throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let source = FileEventSource(url: url)
        let changed = expectation(description: "onChange")
        changed.assertForOverFulfill = false
        source.onChange = { changed.fulfill() }
        XCTAssertTrue(source.start())
        defer { source.stop() }

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("zeile-2\n".utf8))
        try handle.close()

        await fulfillment(of: [changed], timeout: 2.0)
    }

    func testDeleteFiresOnFileGoneAndStopsSource() async throws {
        let url = try makeTempFile()

        let source = FileEventSource(url: url)
        let gone = expectation(description: "onFileGone")
        gone.assertForOverFulfill = false
        source.onFileGone = { gone.fulfill() }
        XCTAssertTrue(source.start())

        try FileManager.default.removeItem(at: url)

        await fulfillment(of: [gone], timeout: 2.0)
        XCTAssertFalse(source.isActive, "Nach Delete muss die Source abgebaut sein")
    }

    func testStartFailsGracefullyWhenOpenFails() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gibt-es-nicht-\(UUID().uuidString).jsonl")
        let source = FileEventSource(url: url, openFile: { _ in -1 })
        XCTAssertFalse(source.start(), "FD < 0 muss als Fehlschlag gemeldet werden")
        XCTAssertFalse(source.isActive)
    }
}

// MARK: - FSEvents-Pfad-Filter (P2 S4)

final class AgentDirectoryEventFilterTests: XCTestCase {
    func testKeepsOnlyJSONLTranscriptPaths() {
        let result = AgentDirectoryEventMonitor.relevantPaths(
            [
                "/u/.claude/projects/-repo/x.jsonl",
                "/u/.claude/projects/-repo/x.json",
                "/u/.claude/projects/-repo/notes.txt",
                "/u/.codex/sessions/2026/07/12/y.jsonl",
            ],
            watchedTranscriptPaths: []
        )
        XCTAssertEqual(result, [
            "/u/.claude/projects/-repo/x.jsonl",
            "/u/.codex/sessions/2026/07/12/y.jsonl",
        ])
    }

    func testDropsProfileInternalJSONL() {
        // Der `.claude-profiles`-Root wird als Ganzes gewatcht — Profil-interne
        // JSONL wie history.jsonl (schreibt bei jedem Prompt) dürfen KEINE
        // Scans auslösen, Transcripts unter <profil>/projects/ schon.
        let result = AgentDirectoryEventMonitor.relevantPaths(
            [
                "/u/.claude-profiles/firma/history.jsonl",
                "/u/.claude-profiles/firma/projects/-repo/x.jsonl",
            ],
            watchedTranscriptPaths: []
        )
        XCTAssertEqual(result, ["/u/.claude-profiles/firma/projects/-repo/x.jsonl"])
    }

    func testDropsLiveWatchedTranscripts() {
        // Aktive In-App-Sessions schreiben sekündlich — ihre Pfade dürfen
        // KEINE Scans auslösen.
        let result = AgentDirectoryEventMonitor.relevantPaths(
            ["/u/.claude/projects/-repo/live.jsonl", "/u/.claude/projects/-repo/neu.jsonl"],
            watchedTranscriptPaths: ["/u/.claude/projects/-repo/live.jsonl"]
        )
        XCTAssertEqual(result, ["/u/.claude/projects/-repo/neu.jsonl"])
    }

    func testEmptyInputYieldsEmptyOutput() {
        XCTAssertTrue(
            AgentDirectoryEventMonitor.relevantPaths([], watchedTranscriptPaths: ["/x.jsonl"]).isEmpty
        )
    }
}
