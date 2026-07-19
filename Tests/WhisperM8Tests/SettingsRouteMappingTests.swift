import XCTest
@testable import WhisperM8

final class SettingsRouteMappingTests: XCTestCase {
    func testRouteIDsResolveToExpectedTargets() {
        let expectations: [(routeID: String, target: SettingsRouteTarget)] = [
            ("api", SettingsRouteTarget(page: .transcription, aiOutputTab: nil, agentChatsTab: nil)),
            ("codex", SettingsRouteTarget(page: .aiOutput, aiOutputTab: .account, agentChatsTab: nil)),
            ("modes", SettingsRouteTarget(page: .aiOutput, aiOutputTab: .modes, agentChatsTab: nil)),
            ("templates", SettingsRouteTarget(page: .aiOutput, aiOutputTab: .templates, agentChatsTab: nil)),
            ("testLab", SettingsRouteTarget(page: .aiOutput, aiOutputTab: .testLab, agentChatsTab: nil)),
            ("outputOverview", SettingsRouteTarget(page: .output, aiOutputTab: nil, agentChatsTab: nil)),
            ("history", SettingsRouteTarget(page: .output, aiOutputTab: nil, agentChatsTab: nil)),
            ("agentChats", SettingsRouteTarget(page: .agentChats, aiOutputTab: nil, agentChatsTab: .workspace)),
            ("claudeCode", SettingsRouteTarget(page: .claudeHooks, aiOutputTab: nil, agentChatsTab: nil)),
            ("hotkey", SettingsRouteTarget(page: .recording, aiOutputTab: nil, agentChatsTab: nil)),
            ("audio", SettingsRouteTarget(page: .recording, aiOutputTab: nil, agentChatsTab: nil)),
            ("behavior", SettingsRouteTarget(page: .general, aiOutputTab: nil, agentChatsTab: nil))
        ] + SettingsPage.allCases.map { page in
            (page.rawValue, SettingsRouteTarget(page: page, aiOutputTab: nil, agentChatsTab: nil))
        }

        for expectation in expectations {
            XCTAssertEqual(
                SettingsRouteTarget.resolve(routeID: expectation.routeID),
                expectation.target,
                "Route \(expectation.routeID) should resolve to \(expectation.target)"
            )
            XCTAssertEqual(
                SettingsPage.page(routeID: expectation.routeID),
                expectation.target.page,
                "Wrapper should keep mapping \(expectation.routeID) to \(expectation.target.page)"
            )
        }
    }

    func testUnknownRouteIDReturnsNil() {
        XCTAssertNil(SettingsRouteTarget.resolve(routeID: "unknown-settings-route"))
        XCTAssertNil(SettingsPage.page(routeID: "unknown-settings-route"))
    }
}
