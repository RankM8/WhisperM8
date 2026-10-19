@testable import WhisperM8
import XCTest

final class UsageResetDateFormatTests: XCTestCase {
    // Samstag, 24.10.2026 19:00 in der lokalen Zeitzone.
    private let saturday = DateComponents(calendar: .current, year: 2026, month: 10, day: 24, hour: 19).date!
    private var threeDaysBefore: Date { saturday.addingTimeInterval(-3 * 86_400) }

    func testEnglishUsesEnglishWeekdayAnd12Hours() {
        let text = UsageResetDateFormat.short(saturday, now: threeDaysBefore, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(text.contains("Sat"), text)
        XCTAssertTrue(text.contains("PM"), text)
    }

    func testGermanUsesGermanWeekdayAnd24Hours() {
        let text = UsageResetDateFormat.short(saturday, now: threeDaysBefore, locale: Locale(identifier: "de_DE"))
        XCTAssertTrue(text.contains("Sa"), text)
        XCTAssertTrue(text.contains("19:00"), text)
    }

    func testWithinADayShowsOnlyTime() {
        let text = UsageResetDateFormat.long(saturday, now: saturday.addingTimeInterval(-3_600), locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(text, "19:00")
    }
}
