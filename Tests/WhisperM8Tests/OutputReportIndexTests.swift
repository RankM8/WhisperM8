import Foundation
import XCTest
@testable import WhisperM8

final class OutputReportIndexTests: XCTestCase {
    func testIndexWriteThroughOnSaveAndDelete() throws {
        let fixture = makeFixture()
        let older = try fixture.store.save(
            makeDraft(createdAt: Date(timeIntervalSince1970: 10), finalTranscript: "older"),
            cleanupPolicy: nil
        )
        let newer = try fixture.store.save(
            makeDraft(createdAt: Date(timeIntervalSince1970: 20), finalTranscript: "newer"),
            cleanupPolicy: nil
        )

        var index = try readIndex(at: fixture.indexURL)
        XCTAssertEqual(index.version, 1)
        XCTAssertEqual(index.entries.map(\.id), [newer.id, older.id])
        XCTAssertEqual(index.entries.first?.title, "Fast · Mail")
        XCTAssertEqual(index.entries.first?.preview, "newer")

        try fixture.store.delete(newer)

        index = try readIndex(at: fixture.indexURL)
        XCTAssertEqual(index.entries.map(\.id), [older.id])
        XCTAssertEqual(fixture.store.reportSummaries(limit: 10).map(\.id), [older.id])
    }

    func testLoadOrRebuildIndexRebuildsMissingIndex() throws {
        let fixture = makeFixture()
        let older = try fixture.store.save(
            makeDraft(createdAt: Date(timeIntervalSince1970: 10), finalTranscript: "older"),
            cleanupPolicy: nil
        )
        let newer = try fixture.store.save(
            makeDraft(createdAt: Date(timeIntervalSince1970: 20), finalTranscript: "newer"),
            cleanupPolicy: nil
        )
        try FileManager.default.removeItem(at: fixture.indexURL)

        let summaries = fixture.store.loadOrRebuildIndex()

        XCTAssertEqual(summaries.map(\.id), [newer.id, older.id])
        XCTAssertEqual(try readIndex(at: fixture.indexURL).entries.map(\.id), [newer.id, older.id])
    }

    func testLoadOrRebuildIndexRebuildsInconsistentIndex() throws {
        let fixture = makeFixture()
        let older = try fixture.store.save(
            makeDraft(createdAt: Date(timeIntervalSince1970: 10), finalTranscript: "older"),
            cleanupPolicy: nil
        )
        let newer = try fixture.store.save(
            makeDraft(createdAt: Date(timeIntervalSince1970: 20), finalTranscript: "newer"),
            cleanupPolicy: nil
        )
        try writeIndex(
            StoredReportIndex(version: 1, entries: [TranscriptRunReportSummary(from: older)]),
            to: fixture.indexURL
        )

        let summaries = fixture.store.loadOrRebuildIndex()

        XCTAssertEqual(summaries.map(\.id), [newer.id, older.id])
        XCTAssertEqual(try readIndex(at: fixture.indexURL).entries.map(\.id), [newer.id, older.id])
    }

    func testPaginationCursorIsStableAcrossThreePagesWithIDTieBreaker() throws {
        let fixture = makeFixture()
        let firstTieID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondTieID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let sameCreatedAt = Date(timeIntervalSince1970: 40)
        let firstTie = try fixture.store.save(
            makeDraft(id: firstTieID, createdAt: sameCreatedAt, finalTranscript: "first tie"),
            cleanupPolicy: nil
        )
        let secondTie = try fixture.store.save(
            makeDraft(id: secondTieID, createdAt: sameCreatedAt, finalTranscript: "second tie"),
            cleanupPolicy: nil
        )
        let middle = try fixture.store.save(
            makeDraft(createdAt: Date(timeIntervalSince1970: 30), finalTranscript: "middle"),
            cleanupPolicy: nil
        )
        let older = try fixture.store.save(
            makeDraft(createdAt: Date(timeIntervalSince1970: 20), finalTranscript: "older"),
            cleanupPolicy: nil
        )
        let oldest = try fixture.store.save(
            makeDraft(createdAt: Date(timeIntervalSince1970: 10), finalTranscript: "oldest"),
            cleanupPolicy: nil
        )

        let page1 = fixture.store.reportSummaries(limit: 2)
        let page2 = fixture.store.reportSummaries(
            before: cursor(from: try XCTUnwrap(page1.last)),
            limit: 2
        )
        let page3 = fixture.store.reportSummaries(
            before: cursor(from: try XCTUnwrap(page2.last)),
            limit: 2
        )

        XCTAssertEqual(page1.map(\.id), [firstTie.id, secondTie.id])
        XCTAssertEqual(page2.map(\.id), [middle.id, older.id])
        XCTAssertEqual(page3.map(\.id), [oldest.id])
    }

    func testSearchFullTextFindsRawTranscriptMatches() throws {
        let fixture = makeFixture()
        let match = try fixture.store.save(
            makeDraft(
                createdAt: Date(timeIntervalSince1970: 20),
                rawTranscript: "Das gesuchte Rohtranskript enthaelt den Build-Hinweis.",
                finalTranscript: "clean output"
            ),
            cleanupPolicy: nil
        )
        let miss = try fixture.store.save(
            makeDraft(
                createdAt: Date(timeIntervalSince1970: 10),
                rawTranscript: "anderer Inhalt",
                finalTranscript: "clean output"
            ),
            cleanupPolicy: nil
        )

        let matches = fixture.store.searchFullText(
            matching: "build-hinweis",
            excluding: [miss.id],
            limit: 10
        )

        XCTAssertEqual(matches.map(\.id), [match.id])
    }

    func testRebuildSkipsCorruptReports() throws {
        let fixture = makeFixture()
        let valid = try fixture.store.save(
            makeDraft(createdAt: Date(timeIntervalSince1970: 10), finalTranscript: "valid"),
            cleanupPolicy: nil
        )
        let corruptID = UUID()
        let corruptDirectory = fixture.reportsDirectory.appendingPathComponent(corruptID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        try Data("{ not valid json".utf8).write(to: corruptDirectory.appendingPathComponent("report.json"))
        try FileManager.default.removeItem(at: fixture.indexURL)

        let summaries = fixture.store.loadOrRebuildIndex()

        XCTAssertEqual(summaries.map(\.id), [valid.id])
        XCTAssertFalse(summaries.contains { $0.id == corruptID })
    }

    func testCleanupUpdatesIndex() throws {
        let fixture = makeFixture()
        let oldest = try fixture.store.save(
            makeDraft(createdAt: Date(timeIntervalSince1970: 10), finalTranscript: "oldest"),
            cleanupPolicy: nil
        )
        let middle = try fixture.store.save(
            makeDraft(createdAt: Date(timeIntervalSince1970: 20), finalTranscript: "middle"),
            cleanupPolicy: nil
        )
        let newest = try fixture.store.save(
            makeDraft(createdAt: Date(timeIntervalSince1970: 30), finalTranscript: "newest"),
            cleanupPolicy: nil
        )

        let result = try fixture.store.cleanup(policy: .init(maxCount: 1), now: Date(timeIntervalSince1970: 40))

        XCTAssertEqual(result.removedCount, 2)
        XCTAssertEqual(try readIndex(at: fixture.indexURL).entries.map(\.id), [newest.id])
        XCTAssertEqual(fixture.store.reportSummaries(limit: 10).map(\.id), [newest.id])
        XCTAssertFalse(fixture.store.reportSummaries(limit: 10).contains { $0.id == oldest.id || $0.id == middle.id })
    }

    private func makeFixture() -> ReportStoreFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8OutputReportIndexTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let reportsDirectory = root.appendingPathComponent("Reports", isDirectory: true)
        return ReportStoreFixture(
            reportsDirectory: reportsDirectory,
            store: TranscriptRunReportStore(reportsDirectory: reportsDirectory)
        )
    }

    private func makeDraft(
        id: UUID = UUID(),
        createdAt: Date,
        modeID: String = OutputMode.rawID,
        sourceAppName: String? = "Mail",
        rawTranscript: String = "raw",
        finalTranscript: String,
        replyIntent: ReplyIntentKind? = nil
    ) -> TranscriptRunReportDraft {
        TranscriptRunReportDraft(
            id: id,
            createdAt: createdAt,
            sourceAppName: sourceAppName,
            sourceBundleIdentifier: nil,
            status: .succeeded,
            errorMessage: nil,
            mode: OutputMode.mode(for: modeID),
            provider: .openai,
            transcriptionModel: .openai_gpt4o,
            language: "de",
            audioDuration: 1,
            contextBundle: .empty,
            renderedPrompt: nil,
            replyIntent: replyIntent,
            visualManifest: nil,
            rawTranscript: rawTranscript,
            finalTranscript: finalTranscript,
            copiedToClipboard: true,
            autoPasteRequested: false
        )
    }

    private func cursor(from summary: TranscriptRunReportSummary) -> (Date, UUID) {
        (summary.createdAt, summary.id)
    }
}

private struct ReportStoreFixture {
    var reportsDirectory: URL
    var store: TranscriptRunReportStore

    var indexURL: URL {
        reportsDirectory.appendingPathComponent("reports-index.json")
    }
}

private struct StoredReportIndex: Codable {
    var version: Int
    var entries: [TranscriptRunReportSummary]
}

private func readIndex(at url: URL) throws -> StoredReportIndex {
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(StoredReportIndex.self, from: data)
}

private func writeIndex(_ index: StoredReportIndex, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(index)
    try data.write(to: url, options: .atomic)
}
