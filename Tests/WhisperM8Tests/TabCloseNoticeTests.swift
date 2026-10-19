import XCTest
@testable import WhisperM8

/// LR-AU-024: Hinweis beim Schließen eines Tabs mit laufendem Chat — nur beim ersten Mal.
final class TabCloseNoticeTests: XCTestCase {
    func testNoticeAppearsOnlyOnceAndOnlyWithRunningProcess() {
        var shown = false
        let notice = TabCloseNotice(wasShown: { shown }, markShown: { shown = true })
        XCTAssertFalse(notice.consume(processRunning: false), "ohne Prozess kein Hinweis")
        XCTAssertFalse(shown, "ohne Prozess wird nichts als gezeigt vermerkt")
        XCTAssertTrue(notice.consume(processRunning: true), "erstes Mal mit laufendem Prozess")
        XCTAssertTrue(shown)
        XCTAssertFalse(notice.consume(processRunning: true), "danach nie wieder")
    }
}
