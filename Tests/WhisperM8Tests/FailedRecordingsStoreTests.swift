import Foundation
import XCTest
@testable import WhisperM8

final class FailedRecordingsStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var storeDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FailedRecordingsStoreTests-\(UUID().uuidString)", isDirectory: true)
        storeDirectory = tempDirectory.appendingPathComponent("FailedRecordings", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func makeStore(
        now: @escaping () -> Date = Date.init,
        maxCount: Int = 10,
        maxAge: TimeInterval = 7 * 24 * 60 * 60
    ) -> FailedRecordingsStore {
        FailedRecordingsStore(
            directoryURL: storeDirectory,
            now: now,
            maxCount: maxCount,
            maxAge: maxAge
        )
    }

    private func makeAudioFile(named name: String = "recording.m4a", contents: String = "fake-audio") throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testPreserveMovesAudioIntoStoreAndWritesSidecar() throws {
        let store = makeStore()
        let audioURL = try makeAudioFile()

        let preserved = try store.preserve(
            audioURL: audioURL,
            audioDuration: 42,
            language: "de",
            errorMessage: "Request timed out."
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path), "Original muss verschoben sein")
        XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.sidecarURL.path))
        XCTAssertEqual(preserved.metadata.audioDuration, 42)
        XCTAssertEqual(preserved.metadata.language, "de")
        XCTAssertEqual(preserved.metadata.errorMessage, "Request timed out.")
        XCTAssertEqual(preserved.metadata.originalFilename, "recording.m4a")
        XCTAssertEqual(try String(contentsOf: preserved.audioURL, encoding: .utf8), "fake-audio")
    }

    func testPreserveKeepsFileInPlaceWhenAlreadyInStore() throws {
        let store = makeStore()
        let audioURL = try makeAudioFile()
        let first = try store.preserve(audioURL: audioURL, audioDuration: 10, language: "de", errorMessage: "Fehler 1")

        // Retry schlug erneut fehl: Datei liegt schon im Store — nur der
        // Sidecar darf sich ändern.
        let second = try store.preserve(audioURL: first.audioURL, audioDuration: 10, language: "de", errorMessage: "Fehler 2")

        XCTAssertEqual(first.audioURL, second.audioURL)
        XCTAssertEqual(second.metadata.errorMessage, "Fehler 2")
        XCTAssertEqual(store.list().count, 1)
    }

    func testListReturnsNewestFirst() throws {
        var current = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(now: { current })

        let old = try store.preserve(audioURL: makeAudioFile(named: "a.m4a"), audioDuration: 1, language: nil, errorMessage: "alt")
        current = current.addingTimeInterval(60)
        let new = try store.preserve(audioURL: makeAudioFile(named: "b.m4a"), audioDuration: 2, language: nil, errorMessage: "neu")

        let listed = store.list()
        XCTAssertEqual(listed.count, 2)
        // `resolvingSymlinksInPath` wegen /var ↔ /private/var im tmp-Verzeichnis.
        XCTAssertEqual(listed.first?.audioURL.resolvingSymlinksInPath(), new.audioURL.resolvingSymlinksInPath())
        XCTAssertEqual(listed.last?.audioURL.resolvingSymlinksInPath(), old.audioURL.resolvingSymlinksInPath())
    }

    func testPruneEnforcesMaxCountByDroppingOldest() throws {
        var current = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(now: { current }, maxCount: 2)

        let first = try store.preserve(audioURL: makeAudioFile(named: "a.m4a"), audioDuration: 1, language: nil, errorMessage: "1")
        current = current.addingTimeInterval(60)
        _ = try store.preserve(audioURL: makeAudioFile(named: "b.m4a"), audioDuration: 2, language: nil, errorMessage: "2")
        current = current.addingTimeInterval(60)
        _ = try store.preserve(audioURL: makeAudioFile(named: "c.m4a"), audioDuration: 3, language: nil, errorMessage: "3")

        let listed = store.list()
        XCTAssertEqual(listed.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.audioURL.path), "Älteste Aufnahme muss weggeräumt sein")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.sidecarURL.path))
    }

    func testPruneRemovesEntriesOlderThanMaxAge() throws {
        var current = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(now: { current }, maxAge: 3600)

        let old = try store.preserve(audioURL: makeAudioFile(named: "a.m4a"), audioDuration: 1, language: nil, errorMessage: "alt")
        current = current.addingTimeInterval(2 * 3600)
        store.prune()

        XCTAssertTrue(store.list().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.audioURL.path))
    }

    func testPruneRemovesOrphanedSidecarsButKeepsFreshOrphanedAudio() throws {
        let store = makeStore()
        let preserved = try store.preserve(audioURL: makeAudioFile(named: "a.m4a"), audioDuration: 1, language: nil, errorMessage: "x")

        // Audio von Hand löschen → Sidecar ist verwaist und muss weg.
        try FileManager.default.removeItem(at: preserved.audioURL)
        // Frisches Audio ohne Sidecar (z. B. Crash zwischen Move und
        // Sidecar-Write) → darf NICHT gelöscht werden.
        let orphanAudio = storeDirectory.appendingPathComponent("orphan.m4a")
        try Data("orphan".utf8).write(to: orphanAudio)

        store.prune()

        XCTAssertFalse(FileManager.default.fileExists(atPath: preserved.sidecarURL.path), "Verwaister Sidecar muss weg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanAudio.path), "Frisches verwaistes Audio bleibt erhalten")
    }

    func testRemoveDeletesAudioAndSidecar() throws {
        let store = makeStore()
        let preserved = try store.preserve(audioURL: makeAudioFile(), audioDuration: 1, language: nil, errorMessage: "x")

        store.remove(preserved)

        XCTAssertFalse(FileManager.default.fileExists(atPath: preserved.audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: preserved.sidecarURL.path))
        XCTAssertTrue(store.list().isEmpty)
    }
}
