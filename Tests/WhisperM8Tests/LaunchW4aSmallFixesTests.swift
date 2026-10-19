import XCTest
@testable import WhisperM8

/// Kleine Fixes der Welle W4a.
final class LaunchW4aSmallFixesTests: XCTestCase {
    /// LR-CLI-004: Maschinell ausgelöste Befehle holen die App nicht nach vorn.
    func testOnlyExplicitOpenActivatesApp() {
        XCTAssertFalse(ControlActivationPolicy.shouldActivate(method: "session.resume", wantsOpen: false))
        XCTAssertFalse(ControlActivationPolicy.shouldActivate(method: "session.new", wantsOpen: false))
        XCTAssertFalse(ControlActivationPolicy.shouldActivate(method: "workspace.unarchive", wantsOpen: false))
        XCTAssertTrue(ControlActivationPolicy.shouldActivate(method: "workspace.unarchive", wantsOpen: true))
        XCTAssertTrue(ControlActivationPolicy.shouldActivate(method: "session.open", wantsOpen: true))
    }
}
