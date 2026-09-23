import XCTest
@testable import WhisperM8

/// Vorfall 23.09.2026: `swift run` ohne Argumente startete die GUI ohne
/// Bundle und stürzte mit SIGABRT ab (Absturzdialog in Dauerschleife).
final class GUILaunchGuardTests: XCTestCase {
    func testBareDebugBinaryIsRefusedWithHint() throws {
        let message = try XCTUnwrap(GUILaunchGuard.refusalMessage(
            bundleURL: URL(fileURLWithPath: "/Users/x/repos/whisperm8/.build/debug"),
            bundleIdentifier: nil
        ))
        XCTAssertTrue(message.contains(".app-Bundle"))
        XCTAssertTrue(message.contains("swift run WhisperM8 --help"))
    }

    func testInstalledAppBundleStartsNormally() {
        XCTAssertNil(GUILaunchGuard.refusalMessage(
            bundleURL: URL(fileURLWithPath: "/Applications/WhisperM8.app"),
            bundleIdentifier: "com.whisperm8.app"
        ))
    }

    func testDirectoryWithoutAppExtensionIsRefusedEvenWithIdentifier() {
        // Ein eingebettetes Info.plist allein macht noch kein Bundle, in dem
        // UserNotifications & Co. funktionieren.
        XCTAssertNotNil(GUILaunchGuard.refusalMessage(
            bundleURL: URL(fileURLWithPath: "/Users/x/repos/whisperm8/.build/release"),
            bundleIdentifier: "com.whisperm8.app"
        ))
    }

    func testRefusalIsUsageErrorNotCrash() {
        XCTAssertEqual(GUILaunchGuard.refusalExitCode, 64)
    }
}
