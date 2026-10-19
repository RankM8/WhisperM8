import XCTest
@testable import WhisperM8

/// Isolierte Test-Instanz (scripts/test-instance.sh): Die Wurzel kommt nur aus
/// der Umgebung, und das Test-Bundle verweigert den Start ohne sie.
final class AppInstanceTests: XCTestCase {
    func testRootOnlyFromAbsoluteEnvironmentPath() {
        XCTAssertNil(AppInstance.resolveTestRoot([:]))
        XCTAssertNil(AppInstance.resolveTestRoot([AppInstance.rootEnvironmentKey: ""]))
        XCTAssertNil(AppInstance.resolveTestRoot([AppInstance.rootEnvironmentKey: "relativ/pfad"]))
        XCTAssertEqual(
            AppInstance.resolveTestRoot([AppInstance.rootEnvironmentKey: " /tmp/wm8-test/ "])?.path,
            "/tmp/wm8-test"
        )
    }

    func testSuiteRunsAsProductionInstance() {
        // Unter `swift test` ist die Variable nicht gesetzt — alle Pfade bleiben echt.
        XCTAssertFalse(AppInstance.isTestInstance)
        XCTAssertEqual(AppInstance.home, FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertEqual(AppInstance.socketDirectorySuffix, "")
        XCTAssertTrue(AppInstance.childEnvironmentOverrides.isEmpty)
        XCTAssertEqual(AppInstance.defaultsDomain, "com.whisperm8.app")
    }

    func testStableHashIsDeterministic() {
        XCTAssertEqual(AppInstance.stableHash("/Users/x/.whisperm8-test-instance"),
                       AppInstance.stableHash("/Users/x/.whisperm8-test-instance"))
        XCTAssertNotEqual(AppInstance.stableHash("/a"), AppInstance.stableHash("/b"))
    }

    func testTestBundleWithoutRootIsRefused() throws {
        let message = try XCTUnwrap(GUILaunchGuard.refusalMessage(
            bundleURL: URL(fileURLWithPath: "/x/.build-test/WhisperM8Test.app"),
            bundleIdentifier: AppInstance.testBundleIdentifier,
            isTestInstance: false
        ))
        XCTAssertTrue(message.contains("test-instance.sh"))
        XCTAssertNil(GUILaunchGuard.refusalMessage(
            bundleURL: URL(fileURLWithPath: "/x/.build-test/WhisperM8Test.app"),
            bundleIdentifier: AppInstance.testBundleIdentifier,
            isTestInstance: true
        ))
    }
}
