import Foundation
import XCTest
@testable import WhisperM8

@MainActor
final class OutputArchiveViewModelTests: XCTestCase {
    func testLatestReportComesFromPersistedStore() throws {
        let store = makeStore()
        let older = try store.save(makeDraft(createdAt: Date(timeIntervalSince1970: 10), finalTranscript: "older"), cleanupPolicy: nil)
        let newer = try store.save(makeDraft(createdAt: Date(timeIntervalSince1970: 20), finalTranscript: "newer"), cleanupPolicy: nil)
        let model = OutputArchiveViewModel(
            store: store,
            latestFallback: OutputArchiveFallback(
                mode: OutputMode.mode(for: OutputMode.cleanID),
                rawTranscript: "fallback raw",
                finalTranscript: "fallback final",
                createdAt: Date(timeIntervalSince1970: 30)
            )
        )

        model.reload()

        XCTAssertEqual(model.latestReport?.id, newer.id)
        XCTAssertNotEqual(model.latestReport?.id, older.id)
        XCTAssertEqual(model.latestReport?.finalTranscript, "newer")
    }

    func testFilteredReportsDelegateToOutputHistoryFilter() throws {
        let store = makeStore()
        let target = try store.save(
            makeDraft(
                createdAt: Date(timeIntervalSince1970: 30),
                modeID: OutputMode.taskID,
                status: .succeeded,
                sourceAppName: "Xcode",
                rawTranscript: "build passed",
                finalTranscript: "target"
            ),
            cleanupPolicy: nil
        )
        _ = try store.save(
            makeDraft(
                createdAt: Date(timeIntervalSince1970: 20),
                modeID: OutputMode.taskID,
                status: .failed,
                sourceAppName: "Xcode",
                rawTranscript: "build passed",
                finalTranscript: "wrong status"
            ),
            cleanupPolicy: nil
        )
        _ = try store.save(
            makeDraft(
                createdAt: Date(timeIntervalSince1970: 10),
                modeID: OutputMode.cleanID,
                status: .succeeded,
                sourceAppName: "Xcode",
                rawTranscript: "build passed",
                finalTranscript: "wrong scope"
            ),
            cleanupPolicy: nil
        )
        let model = OutputArchiveViewModel(store: store)
        model.reload()

        model.scope = .tasks
        model.status = .succeeded
        model.searchText = "build"

        let expected = OutputHistoryFilter(
            scope: .tasks,
            status: .succeeded,
            searchText: "build"
        ).apply(to: model.reports)
        XCTAssertEqual(model.filteredReports, expected)
        XCTAssertEqual(model.filteredReports.map(\.id), [target.id])
    }

    func testDeleteRemovesReportFromStoreAndReloads() throws {
        let store = makeStore()
        let report = try store.save(makeDraft(createdAt: Date(timeIntervalSince1970: 10), finalTranscript: "delete me"), cleanupPolicy: nil)
        let survivor = try store.save(makeDraft(createdAt: Date(timeIntervalSince1970: 20), finalTranscript: "keep me"), cleanupPolicy: nil)
        let model = OutputArchiveViewModel(store: store)
        model.reload()

        model.delete(report: report)

        XCTAssertFalse(store.recentReports(limit: 10).contains { $0.id == report.id })
        XCTAssertTrue(store.recentReports(limit: 10).contains { $0.id == survivor.id })
        XCTAssertFalse(model.reports.contains { $0.id == report.id })
    }

    func testSelectReportIDSetsSelection() throws {
        let store = makeStore()
        let report = try store.save(makeDraft(createdAt: Date(timeIntervalSince1970: 10), finalTranscript: "selected"), cleanupPolicy: nil)
        let model = OutputArchiveViewModel(store: store)
        model.reload()

        model.select(reportID: report.id)

        XCTAssertEqual(model.selectedReportID, report.id)
        XCTAssertEqual(model.selectedReport?.id, report.id)
    }

    func testSelectedReportCanStayOutsideCurrentFilter() throws {
        let store = makeStore()
        let hiddenByFilter = try store.save(
            makeDraft(
                createdAt: Date(timeIntervalSince1970: 20),
                modeID: OutputMode.cleanID,
                status: .failed,
                finalTranscript: "hidden but selected"
            ),
            cleanupPolicy: nil
        )
        _ = try store.save(
            makeDraft(
                createdAt: Date(timeIntervalSince1970: 10),
                modeID: OutputMode.taskID,
                status: .succeeded,
                finalTranscript: "visible"
            ),
            cleanupPolicy: nil
        )
        let model = OutputArchiveViewModel(store: store)
        model.reload()

        model.select(reportID: hiddenByFilter.id)
        model.scope = .tasks
        model.status = .succeeded

        XCTAssertFalse(model.filteredReports.contains { $0.id == hiddenByFilter.id })
        XCTAssertEqual(model.selectedReportID, hiddenByFilter.id)
        XCTAssertEqual(model.selectedReport?.id, hiddenByFilter.id)
    }

    func testLatestFallbackKeepsRawAndFinalOutputSeparately() {
        let fallback = OutputArchiveFallback(
            mode: OutputMode.mode(for: OutputMode.cleanID),
            rawTranscript: "raw fallback",
            finalTranscript: "final fallback",
            createdAt: Date(timeIntervalSince1970: 40)
        )
        let model = OutputArchiveViewModel(store: makeStore(), latestFallback: fallback)

        XCTAssertEqual(model.latestFallback?.rawTranscript, "raw fallback")
        XCTAssertEqual(model.latestFallback?.finalTranscript, "final fallback")
        XCTAssertEqual(model.latestFallback?.shortSummary, "final fallback")
        XCTAssertTrue(model.latestFallback?.hasVisibleOutput == true)
    }

    func testSelectUnknownReportIDClearsExplicitSelectionAndFallsBackToFirstFilteredReport() throws {
        let store = makeStore()
        let report = try store.save(makeDraft(createdAt: Date(timeIntervalSince1970: 10), finalTranscript: "fallback"), cleanupPolicy: nil)
        let model = OutputArchiveViewModel(store: store)
        model.reload()

        model.select(reportID: UUID())

        XCTAssertNil(model.selectedReportID)
        XCTAssertEqual(model.selectedReport?.id, report.id)
    }

    private func makeStore() -> TranscriptRunReportStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8OutputArchiveTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return TranscriptRunReportStore(
            reportsDirectory: root.appendingPathComponent("Reports", isDirectory: true)
        )
    }

    private func makeDraft(
        createdAt: Date,
        modeID: String = OutputMode.rawID,
        status: TranscriptRunStatus = .succeeded,
        sourceAppName: String? = "Mail",
        rawTranscript: String = "raw",
        finalTranscript: String
    ) -> TranscriptRunReportDraft {
        TranscriptRunReportDraft(
            createdAt: createdAt,
            sourceAppName: sourceAppName,
            sourceBundleIdentifier: nil,
            status: status,
            errorMessage: status == .failed ? "failed" : nil,
            mode: OutputMode.mode(for: modeID),
            provider: .openai,
            transcriptionModel: .openai_gpt4o,
            language: "de",
            audioDuration: 1,
            contextBundle: .empty,
            renderedPrompt: nil,
            replyIntent: nil,
            visualManifest: nil,
            rawTranscript: rawTranscript,
            finalTranscript: finalTranscript,
            copiedToClipboard: true,
            autoPasteRequested: false
        )
    }
}
