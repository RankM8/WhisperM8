import Foundation
import XCTest
@testable import WhisperM8

/// LR-DIK-017 (Cleanup arbeitet aus dem Index statt Voll-Decode) und
/// LR-DIK-019 (Löschschalter erreicht Archiv- und Paste-Kopien).
final class ReportArchiveCostTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        func reset() { lock.lock(); value = 0; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReportArchiveCost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func draft(createdAt: Date = Date(), bundle: TranscriptContextBundle = .empty) -> TranscriptRunReportDraft {
        TranscriptRunReportDraft(
            createdAt: createdAt,
            status: .succeeded,
            mode: OutputMode.mode(for: OutputMode.rawID),
            provider: .openai,
            transcriptionModel: .openai_gpt4o,
            language: "de",
            audioDuration: 1,
            contextBundle: bundle,
            copiedToClipboard: true,
            autoPasteRequested: false
        )
    }

    func testSaveWithProductionCleanupDoesNotDecodeTheWholeArchive() throws {
        let counter = Counter()
        let directory = root.appendingPathComponent("Reports", isDirectory: true)
        let real = TranscriptRunReportStore(reportsDirectory: directory)
        for index in 0..<120 {
            _ = try real.save(draft(createdAt: Date(timeIntervalSinceNow: Double(-index - 10))), cleanupPolicy: nil)
        }
        let counting = TranscriptRunReportStore(reportsDirectory: directory, reportLoader: { url in
            counter.increment()
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(TranscriptRunReport.self, from: data)
        })
        _ = counting.loadOrRebuildIndex()   // Index aufwärmen
        counter.reset()

        _ = try counting.save(draft(), cleanupPolicy: .productionDefault)

        XCTAssertLessThanOrEqual(counter.count, 1, "Cleanup muss aus dem Index arbeiten, nicht jeden Report dekodieren")
    }

    func testDeleteSwitchStoresNoAttachmentCopiesInArchive() throws {
        let source = root.appendingPathComponent("shot.png")
        try Data("png".utf8).write(to: source)
        let store = TranscriptRunReportStore(reportsDirectory: root.appendingPathComponent("Reports", isDirectory: true))
        let bundle = TranscriptContextBundle(screenshots: [ContextAttachment(kind: .screenshot, fileURL: source, thumbnailURL: source)])

        let report = try store.save(draft(bundle: bundle), storeAttachmentFiles: false)

        let attachmentsDir = root.appendingPathComponent("Reports/\(report.id.uuidString)/Attachments")
        let stored = (try? FileManager.default.contentsOfDirectory(atPath: attachmentsDir.path)) ?? []
        XCTAssertTrue(stored.isEmpty, "keine Bildkopien im Archiv: \(stored)")
        XCTAssertNil(report.attachments.first?.storedPath)
        XCTAssertNil(report.attachments.first?.thumbnailPath)

        let kept = try store.save(draft(bundle: bundle))
        XCTAssertNotNil(kept.attachments.first?.storedPath, "ohne Schalter bleibt das Archiv wie bisher")
    }

    func testDeliveryCopiesAreRemovedAfterGracePeriod() throws {
        let source = root.appendingPathComponent("shot.png")
        try Data("png".utf8).write(to: source)
        let deliveryRoot = root.appendingPathComponent("Delivery", isDirectory: true)
        let builder = VisualAttachmentDeliveryBuilder(rootDirectory: deliveryRoot)
        var mode = OutputMode.mode(for: OutputMode.promptID)
        mode.pasteVisualAttachments = true
        let bundle = TranscriptContextBundle(screenshots: [ContextAttachment(kind: .screenshot, fileURL: source)])
        let attachments = try builder.build(contextBundle: bundle, mode: mode, maxAttachments: 3)
        let runDirectory = try XCTUnwrap(attachments.first?.fileURL.deletingLastPathComponent())
        XCTAssertTrue(FileManager.default.fileExists(atPath: runDirectory.path))

        builder.removeDeliveryCopiesLater(attachments, after: 0.2)

        let deadline = Date().addingTimeInterval(5)
        while FileManager.default.fileExists(atPath: runDirectory.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: runDirectory.path))
    }
}
