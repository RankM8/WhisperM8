import XCTest
@testable import WhisperM8

final class SettingsRouteMappingTests: XCTestCase {
    func testLegacyRouteIDsMapToSettingsPages() {
        let expectations: [(routeID: String, page: SettingsPage)] = [
            ("api", .transcription),
            ("codex", .aiOutput),
            ("outputOverview", .output),
            ("history", .output),
            ("modes", .aiOutput),
            ("templates", .aiOutput),
            ("testLab", .aiOutput),
            ("agentChats", .agentChats),
            ("claudeCode", .agentChats),
            ("permissions", .permissions),
            ("hotkey", .recording),
            ("audio", .recording),
            ("behavior", .general),
            ("cli", .cli),
            ("about", .about)
        ]

        for expectation in expectations {
            XCTAssertEqual(
                SettingsPage.page(routeID: expectation.routeID),
                expectation.page,
                "Route \(expectation.routeID) should map to \(expectation.page)"
            )
        }
    }

    func testRawValuesMapOneToOne() {
        for page in SettingsPage.allCases {
            XCTAssertEqual(SettingsPage.page(routeID: page.rawValue), page)
        }
    }

    func testUnknownRouteIDReturnsNil() {
        XCTAssertNil(SettingsPage.page(routeID: "unknown-settings-route"))
    }
}
