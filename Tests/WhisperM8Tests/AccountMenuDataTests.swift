import XCTest
@testable import WhisperM8

@MainActor
final class AccountMenuDataTests: XCTestCase {
    func testLoadsOncePerTTL() {
        var loads = 0
        var clock = Date(timeIntervalSince1970: 1_000)
        let cache = MenuValueCache(ttl: 2, now: { clock }) { () -> Int in
            loads += 1
            return loads
        }

        for _ in 0..<500 { XCTAssertEqual(cache.value, 1) }
        XCTAssertEqual(loads, 1, "pro Zeile und Render darf nicht neu geladen werden")

        clock.addTimeInterval(1.9)
        XCTAssertEqual(cache.value, 1)
        clock.addTimeInterval(0.1)
        XCTAssertEqual(cache.value, 2, "nach Ablauf der TTL frisch von der Platte")
    }

    func testInvalidateForcesReload() {
        var loads = 0
        let cache = MenuValueCache(ttl: 60, now: { Date(timeIntervalSince1970: 1_000) }) { () -> Int in
            loads += 1
            return loads
        }
        XCTAssertEqual(cache.value, 1)
        cache.invalidate()
        XCTAssertEqual(cache.value, 2, "eigener Umzug/Rückgängig muss sofort sichtbar sein")
    }
}
