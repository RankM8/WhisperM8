import XCTest
@testable import WhisperM8

/// Sliding-Window der Transcript-Ansichten (Hang-Fix 2026-07-16): harte
/// Obergrenze gleichzeitig gerenderter Items, Kopf-/Tail-Wachstum, Paging.
final class TranscriptWindowTests: XCTestCase {

    private func makeWindow(initial: Int = 40, batch: Int = 40, max maxSize: Int = 160) -> TranscriptWindow {
        TranscriptWindow(initialSize: initial, batchSize: batch, maxSize: maxSize)
    }

    // MARK: - Erstbefüllung & Reset

    func testResetShowsTailWithInitialSize() {
        var window = makeWindow()
        window.reset(total: 500)
        XCTAssertEqual(window.start, 460)
        XCTAssertEqual(window.end, 500)
        XCTAssertEqual(window.count, 40)
        XCTAssertTrue(window.followsTail)
        XCTAssertEqual(window.hiddenEarlierCount, 460)
        XCTAssertEqual(window.hiddenLaterCount, 0)
    }

    func testFirstFillViaTailChangeUsesInitialSize() {
        var window = makeWindow()
        window.updateForTailChange(total: 500)
        XCTAssertEqual(window.count, 40)
        XCTAssertTrue(window.followsTail)
    }

    func testResetWithFewerItemsThanInitialShowsAll() {
        var window = makeWindow()
        window.reset(total: 12)
        XCTAssertEqual(window.start, 0)
        XCTAssertEqual(window.end, 12)
    }

    // MARK: - Tail-Wachstum (Live-Append)

    func testTailGrowthFollowsWhenPinned() {
        var window = makeWindow()
        window.reset(total: 100)
        window.updateForTailChange(total: 110)
        XCTAssertEqual(window.end, 110)
        XCTAssertTrue(window.followsTail)
    }

    func testTailGrowthIsCappedAtMaxSize() {
        var window = makeWindow(initial: 40, batch: 40, max: 60)
        window.reset(total: 100)
        window.updateForTailChange(total: 300)
        XCTAssertEqual(window.end, 300)
        XCTAssertEqual(window.count, 60)
    }

    func testTailGrowthKeepsPositionWhenPagedAway() {
        var window = makeWindow(initial: 40, batch: 40, max: 60)
        window.reset(total: 200)
        window.pageUp() // Fenster verlässt das Ende
        let (start, end) = (window.start, window.end)
        XCTAssertFalse(window.followsTail)
        window.updateForTailChange(total: 250)
        XCTAssertEqual(window.start, start)
        XCTAssertEqual(window.end, end)
        XCTAssertEqual(window.hiddenLaterCount, 250 - end)
    }

    func testShrinkResetsToTailWindow() {
        var window = makeWindow()
        window.reset(total: 500)
        window.pageUp()
        window.updateForTailChange(total: 80) // Session-Wechsel
        XCTAssertEqual(window.end, 80)
        XCTAssertEqual(window.count, 40)
    }

    // MARK: - Kopf-Wachstum (Disk-Nachladen prependet)

    func testHeadGrowthKeepsVisibleItemsAndExposesOneBatch() {
        var window = makeWindow(initial: 40, batch: 40, max: 160)
        window.reset(total: 100) // zeigt 60..<100
        window.updateForHeadGrowth(total: 400) // 300 ältere prependet
        // Gleiche Items wären 360..<400; pageUp deckt eine Batch auf.
        XCTAssertEqual(window.start, 320)
        XCTAssertEqual(window.end, 400)
        XCTAssertEqual(window.total, 400)
    }

    func testHeadGrowthRespectsMaxSize() {
        var window = makeWindow(initial: 40, batch: 40, max: 60)
        window.reset(total: 100)
        for _ in 0..<5 { window.pageUp() } // Fenster ist am Max
        window.updateForHeadGrowth(total: 500)
        XCTAssertLessThanOrEqual(window.count, 60)
    }

    // MARK: - Paging

    func testPageUpDropsNewestBeyondMaxSize() {
        var window = makeWindow(initial: 40, batch: 40, max: 60)
        window.reset(total: 500) // 460..<500
        window.pageUp() // 420..<480 (Max 60 → Ende fällt)
        XCTAssertEqual(window.start, 420)
        XCTAssertEqual(window.end, 480)
        XCTAssertEqual(window.hiddenLaterCount, 20)
        XCTAssertFalse(window.followsTail)
    }

    func testPageUpStopsAtStart() {
        var window = makeWindow()
        window.reset(total: 30)
        XCTAssertFalse(window.pageUp())
    }

    func testPageDownMovesBackTowardsTail() {
        var window = makeWindow(initial: 40, batch: 40, max: 60)
        window.reset(total: 500)
        window.pageUp()
        window.pageUp() // 380..<440
        XCTAssertTrue(window.pageDown()) // 380..<480 → Max 60 → 420..<480
        XCTAssertEqual(window.end, 480)
        XCTAssertEqual(window.count, 60)
    }

    func testJumpToTailRestoresInitialTailWindow() {
        var window = makeWindow()
        window.reset(total: 500)
        for _ in 0..<8 { window.pageUp() }
        window.jumpToTail()
        XCTAssertEqual(window.end, 500)
        XCTAssertEqual(window.count, 40)
        XCTAssertTrue(window.followsTail)
    }

    // MARK: - Slice-Sicherheit

    func testSliceClampsWhenListIsShorterThanWindowState() {
        var window = makeWindow()
        window.reset(total: 500)
        let items = Array(0..<10) // Liste kürzer als Fensterzustand (Race)
        let slice = window.slice(of: items)
        XCTAssertTrue(slice.isEmpty || slice.endIndex <= items.count)
    }

    func testSliceReturnsWindowedItems() {
        var window = makeWindow(initial: 3, batch: 3, max: 5)
        window.reset(total: 10)
        let slice = window.slice(of: Array(0..<10))
        XCTAssertEqual(Array(slice), [7, 8, 9])
    }

    // MARK: - Tabellen-Budget

    func testTableBudgetFallsBackForHugeTables() {
        let smallTable = MarkdownTable(headers: ["a", "b"], rows: [["1", "2"]])
        XCTAssertFalse(TranscriptRenderLimits.tableExceedsBudget(smallTable))

        let manyRows = MarkdownTable(
            headers: ["a"],
            rows: Array(repeating: ["x"], count: TranscriptRenderLimits.maxTableRows + 1)
        )
        XCTAssertTrue(TranscriptRenderLimits.tableExceedsBudget(manyRows))

        let manyColumns = MarkdownTable(
            headers: Array(repeating: "h", count: TranscriptRenderLimits.maxTableColumns + 1),
            rows: []
        )
        XCTAssertTrue(TranscriptRenderLimits.tableExceedsBudget(manyColumns))
    }
}
