import Foundation
import XCTest
@testable import WhisperM8

@MainActor
final class OutputArchiveViewModelTests: XCTestCase {
    func testInitialLoadLoadsExactlyPageSize() async throws {
        let store = makeStore()
        let reports = try saveReports(count: OutputArchiveViewModel.pageSize + 5, in: store)
        let model = OutputArchiveViewModel(store: store)

        await model.initialLoad()

        XCTAssertEqual(model.reports.count, OutputArchiveViewModel.pageSize)
        XCTAssertEqual(model.latestReport?.id, reports.last?.id)
        XCTAssertTrue(model.hasMore)
    }

    func testLoadMoreAppendsNextPageAndClearsHasMoreAtEnd() async throws {
        let store = makeStore()
        try saveReports(count: OutputArchiveViewModel.pageSize + 5, in: store)
        let model = OutputArchiveViewModel(store: store)

        await model.initialLoad()
        await model.loadMore()

        XCTAssertEqual(model.reports.count, OutputArchiveViewModel.pageSize + 5)
        XCTAssertFalse(model.hasMore)
    }

    func testSelectLoadsFullReport() async throws {
        let store = makeStore()
        _ = try store.save(
            makeDraft(
                createdAt: Date(timeIntervalSince1970: 20),
                finalTranscript: "newer"
            ),
            cleanupPolicy: nil
        )
        let target = try store.save(
            makeDraft(
                createdAt: Date(timeIntervalSince1970: 10),
                rawTranscript: "full raw text",
                finalTranscript: "full final text"
            ),
            cleanupPolicy: nil
        )
        let model = OutputArchiveViewModel(store: store)

        await model.initialLoad()
        model.select(id: target.id)
        try await waitUntil {
            model.selectedReport?.id == target.id && !model.isLoadingDetail
        }

        XCTAssertEqual(model.selectedReportID, target.id)
        XCTAssertEqual(model.selectedReport?.rawTranscript, "full raw text")
        XCTAssertEqual(model.selectedReport?.finalTranscript, "full final text")
    }

    func testSearchUsesSummaryImmediatelyAndFullTextInBackground() async throws {
        let store = makeStore()
        let target = try store.save(
            makeDraft(
                createdAt: Date(timeIntervalSince1970: 30),
                rawTranscript: String(repeating: "a", count: 300) + " deepneedle",
                finalTranscript: "ordinary visible summary"
            ),
            cleanupPolicy: nil
        )
        let summaryTarget = try store.save(
            makeDraft(
                createdAt: Date(timeIntervalSince1970: 20),
                sourceAppName: "NeedleApp",
                rawTranscript: "raw",
                finalTranscript: "summary match"
            ),
            cleanupPolicy: nil
        )
        _ = try store.save(
            makeDraft(
                createdAt: Date(timeIntervalSince1970: 10),
                rawTranscript: "raw",
                finalTranscript: "unrelated"
            ),
            cleanupPolicy: nil
        )
        let model = OutputArchiveViewModel(store: store)

        await model.initialLoad()
        model.searchText = "NeedleApp"

        XCTAssertEqual(model.filteredReports.map(\.id), [summaryTarget.id])

        model.searchText = "deepneedle"
        XCTAssertFalse(model.filteredReports.contains { $0.id == target.id })

        try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            model.filteredReports.contains { $0.id == target.id } && !model.searchingDeeper
        }

        XCTAssertEqual(model.filteredReports.map(\.id), [target.id])
    }

    func testDeleteRemovesLoadedSummaryWithoutReloadingPage() async throws {
        let store = makeStore()
        try saveReports(count: OutputArchiveViewModel.pageSize + 5, in: store)
        let model = OutputArchiveViewModel(store: store)

        await model.initialLoad()
        let target = try XCTUnwrap(model.reports.dropFirst(10).first)
        await model.delete(id: target.id)

        XCTAssertNil(store.loadReport(id: target.id))
        XCTAssertFalse(model.reports.contains { $0.id == target.id })
        XCTAssertEqual(model.reports.count, OutputArchiveViewModel.pageSize - 1)
        XCTAssertTrue(model.hasMore)
    }

    func testFiltersScopeStatusAndSearchOnSummaries() async throws {
        let store = makeStore()
        let target = try store.save(
            makeDraft(
                createdAt: Date(timeIntervalSince1970: 30),
                modeID: OutputMode.taskID,
                status: .succeeded,
                sourceAppName: "Xcode",
                rawTranscript: "build passed",
                finalTranscript: "target summary"
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
                finalTranscript: "wrong status target summary"
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
                finalTranscript: "wrong scope target summary"
            ),
            cleanupPolicy: nil
        )
        let model = OutputArchiveViewModel(store: store)

        await model.initialLoad()
        model.scope = .tasks
        model.status = .succeeded
        model.searchText = "target"

        XCTAssertEqual(model.filteredReports.map(\.id), [target.id])
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

    @discardableResult
    private func saveReports(
        count: Int,
        in store: TranscriptRunReportStore
    ) throws -> [TranscriptRunReport] {
        try (0..<count).map { index in
            try store.save(
                makeDraft(
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    finalTranscript: "report \(index)"
                ),
                cleanupPolicy: nil
            )
        }
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
        finalTranscript: String? = "final"
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

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 500_000_000,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .nanoseconds(Int(timeoutNanoseconds))
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail("Bedingung wurde nicht rechtzeitig erfuellt")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
