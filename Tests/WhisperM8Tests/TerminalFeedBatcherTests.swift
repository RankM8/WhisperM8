import Foundation
import XCTest
@testable import WhisperM8

/// Feed-Drosselung der Hintergrund-Panes (Plan F11): exakte Byte-Reihenfolge,
/// genau ein geplanter Flush, Fokus-/High-Water-Flush, übergroße Chunks.
final class TerminalFeedBatcherTests: XCTestCase {
    /// Test-Harness: fängt Feeds ab und feuert geplante Flushes manuell.
    private final class Harness {
        var fed: [(bytes: [UInt8], batched: Bool)] = []
        var scheduledFires: [() -> Void] = []
        var cancelCount = 0
        private(set) var batcher: TerminalFeedBatcher!

        init(maxPendingBytes: Int = 16) {
            batcher = TerminalFeedBatcher(
                maxPendingBytes: maxPendingBytes,
                feed: { [weak self] bytes, batched in
                    self?.fed.append((Array(bytes), batched))
                },
                scheduleFlush: { [weak self] fire in
                    self?.scheduledFires.append(fire)
                    return {
                        self?.cancelCount += 1
                        self?.scheduledFires.removeAll()
                    }
                }
            )
        }

        var allBytes: [UInt8] { fed.flatMap(\.bytes) }

        func fireScheduled() {
            let fires = scheduledFires
            scheduledFires = []
            fires.forEach { $0() }
        }
    }

    func testPassthroughWithoutThrottling() {
        let h = Harness()
        h.batcher.receive([1, 2, 3][...])
        XCTAssertEqual(h.fed.count, 1)
        XCTAssertEqual(h.fed[0].bytes, [1, 2, 3])
        XCTAssertFalse(h.fed[0].batched, "Fokus-Pfad ist kein gebündelter Flush")
        XCTAssertTrue(h.scheduledFires.isEmpty)
    }

    func testThrottlingBuffersAndSchedulesExactlyOneFlush() {
        let h = Harness()
        h.batcher.isThrottling = true
        h.batcher.receive([1][...])
        h.batcher.receive([2][...])
        h.batcher.receive([3][...])
        XCTAssertTrue(h.fed.isEmpty, "noch nichts verarbeitet")
        XCTAssertEqual(h.scheduledFires.count, 1, "genau EIN geplanter Flush")

        h.fireScheduled()
        XCTAssertEqual(h.fed.count, 1)
        XCTAssertEqual(h.fed[0].bytes, [1, 2, 3], "FIFO über Chunks hinweg")
        XCTAssertTrue(h.fed[0].batched)
        XCTAssertEqual(h.batcher.pendingByteCount, 0)
    }

    func testDisablingThrottleFlushesImmediately() {
        let h = Harness()
        h.batcher.isThrottling = true
        h.batcher.receive([1, 2][...])
        h.batcher.isThrottling = false
        XCTAssertEqual(h.allBytes, [1, 2], "Fokus-Flush verarbeitet den Rückstand sofort")
        XCTAssertEqual(h.cancelCount, 1, "geplanter Flush wurde abgebrochen")

        // Danach direkter Pfad — keine neue Planung.
        h.batcher.receive([3][...])
        XCTAssertEqual(h.allBytes, [1, 2, 3])
        XCTAssertTrue(h.scheduledFires.isEmpty)
    }

    func testHighWaterFlushesOlderPrefixFirst() {
        let h = Harness(maxPendingBytes: 4)
        h.batcher.isThrottling = true
        h.batcher.receive([1, 2, 3][...])
        // 3 + 2 > 4 → älterer Prefix wird SOFORT verarbeitet, dann gepuffert.
        h.batcher.receive([4, 5][...])
        XCTAssertEqual(h.fed.count, 1)
        XCTAssertEqual(h.fed[0].bytes, [1, 2, 3], "kein Drop, keine Umordnung")
        XCTAssertEqual(h.batcher.pendingByteCount, 2)

        h.fireScheduled()
        XCTAssertEqual(h.allBytes, [1, 2, 3, 4, 5])
    }

    func testOversizedChunkIsFedDirectlyAfterPrefixFlush() {
        let h = Harness(maxPendingBytes: 4)
        h.batcher.isThrottling = true
        h.batcher.receive([1][...])
        h.batcher.receive([2, 3, 4, 5, 6][...]) // >= Grenze
        XCTAssertEqual(h.fed.count, 2)
        XCTAssertEqual(h.fed[0].bytes, [1], "Prefix zuerst (FIFO)")
        XCTAssertEqual(h.fed[1].bytes, [2, 3, 4, 5, 6], "übergroßer Chunk direkt")
        XCTAssertEqual(h.batcher.pendingByteCount, 0)
    }

    func testScheduledFlushAfterFireAllowsNewScheduling() {
        let h = Harness()
        h.batcher.isThrottling = true
        h.batcher.receive([1][...])
        h.fireScheduled()
        h.batcher.receive([2][...])
        XCTAssertEqual(h.scheduledFires.count, 1, "nach dem Feuern wird neu geplant")
        h.fireScheduled()
        XCTAssertEqual(h.allBytes, [1, 2])
    }

    func testFlushPendingIsNoOpWhenEmpty() {
        let h = Harness()
        h.batcher.isThrottling = true
        h.batcher.flushPending()
        XCTAssertTrue(h.fed.isEmpty)
    }
}
