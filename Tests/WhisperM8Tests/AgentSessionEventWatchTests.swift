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
    func testKeepsOnlyJSONLPaths() {
        let result = AgentDirectoryEventMonitor.relevantPaths(
            ["/a/x.jsonl", "/a/x.json", "/a/notes.txt", "/b/y.jsonl"],
            watchedTranscriptPaths: []
        )
        XCTAssertEqual(result, ["/a/x.jsonl", "/b/y.jsonl"])
    }

    func testDropsLiveWatchedTranscripts() {
        // Aktive In-App-Sessions schreiben sekündlich — ihre Pfade dürfen
        // KEINE Scans auslösen.
        let result = AgentDirectoryEventMonitor.relevantPaths(
            ["/a/live.jsonl", "/a/neu.jsonl"],
            watchedTranscriptPaths: ["/a/live.jsonl"]
        )
        XCTAssertEqual(result, ["/a/neu.jsonl"])
    }

    func testEmptyInputYieldsEmptyOutput() {
        XCTAssertTrue(
            AgentDirectoryEventMonitor.relevantPaths([], watchedTranscriptPaths: ["/x.jsonl"]).isEmpty
        )
    }
}
