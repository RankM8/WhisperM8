import XCTest
@testable import WhisperM8

/// Sidecar-Ablage der Terminal-Snapshots (Stufe 1, Plaintext): Roundtrip,
/// Versions-Header, Zeilen-Deckel, Löschung. I/O via injiziertem Temp-Dir.
final class TerminalSnapshotStoreTests: XCTestCase {
    private var directory: URL!
    private var store: TerminalSnapshotStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalSnapshotStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = TerminalSnapshotStore(directory: directory)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - prepared() (pur)

    func testPreparedTrimsTrailingBlankLines() {
        let raw = "eins\nzwei\n   \n\n\n"
        XCTAssertEqual(TerminalSnapshotStore.prepared(raw), "eins\nzwei")
    }

    func testPreparedCapsToLastMaxLines() {
        let raw = (1...10).map(String.init).joined(separator: "\n")
        let prepared = TerminalSnapshotStore.prepared(raw, maxLines: 3)
        XCTAssertEqual(prepared, "8\n9\n10")
    }

    func testPreparedKeepsResumeHintAtTail() {
        let lines = Array(repeating: "output", count: 5000)
            + ["Resume this session with:", "claude --resume 43551f1f"]
        let prepared = TerminalSnapshotStore.prepared(lines.joined(separator: "\n"))
        XCTAssertTrue(prepared.hasSuffix("claude --resume 43551f1f"))
        XCTAssertEqual(prepared.components(separatedBy: "\n").count, TerminalSnapshotStore.maxLines)
    }

    // MARK: - Roundtrip

    func testSaveAndLoadRoundtrip() {
        let id = UUID()
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        store.save(sessionID: id, text: "Press Ctrl-C again to exit\nclaude --resume abc", capturedAt: capturedAt)

        XCTAssertTrue(store.hasSnapshot(sessionID: id))
        let loaded = store.load(sessionID: id)
        XCTAssertEqual(loaded?.text, "Press Ctrl-C again to exit\nclaude --resume abc")
        // ISO8601 hat Sekunden-Auflösung.
        XCTAssertEqual(loaded.map { $0.capturedAt.timeIntervalSince1970.rounded() },
                       capturedAt.timeIntervalSince1970.rounded())
    }

    func testSaveDiscardsEmptyBuffers() {
        let id = UUID()
        store.save(sessionID: id, text: "\n\n   \n")
        XCTAssertFalse(store.hasSnapshot(sessionID: id))
        XCTAssertNil(store.load(sessionID: id))
    }

    func testLoadReturnsNilForMissingSnapshot() {
        XCTAssertNil(store.load(sessionID: UUID()))
        XCTAssertFalse(store.hasSnapshot(sessionID: UUID()))
    }

    /// Unbekannte (neuere) Header-Version → nil, Aufrufer fällt auf die
    /// Transcript-Ansicht zurück.
    func testLoadRejectsUnknownHeaderVersion() throws {
        let id = UUID()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = "{\"version\":99,\"capturedAt\":\"2026-07-16T12:00:00Z\"}\nInhalt"
        try Data(payload.utf8).write(to: store.fileURL(sessionID: id))
        XCTAssertNil(store.load(sessionID: id))
    }

    func testLoadRejectsCorruptHeader() throws {
        let id = UUID()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("kein json\nInhalt".utf8).write(to: store.fileURL(sessionID: id))
        XCTAssertNil(store.load(sessionID: id))
    }

    // MARK: - Löschung

    func testDeleteRemovesSnapshot() {
        let id = UUID()
        store.save(sessionID: id, text: "inhalt")
        XCTAssertTrue(store.hasSnapshot(sessionID: id))
        store.delete(sessionID: id)
        XCTAssertFalse(store.hasSnapshot(sessionID: id))
        // Idempotent.
        store.delete(sessionID: id)
    }

    func testBulkDeleteRemovesAllGivenSessions() {
        let ids = [UUID(), UUID(), UUID()]
        for id in ids {
            store.save(sessionID: id, text: "inhalt \(id)")
        }
        store.delete(sessionIDs: ids)
        for id in ids {
            XCTAssertFalse(store.hasSnapshot(sessionID: id))
        }
    }
}
