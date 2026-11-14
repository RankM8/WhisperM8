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

    /// WM8-63: Die Chats der Test-Instanz bekommen ein eigenes Login-Fach im
    /// Schlüsselbund; HOME allein trennt Claudes Login nicht.
    func testTestChatsGetTheirOwnClaudeKeychainFolder() {
        let root = URL(fileURLWithPath: "/Users/x/.whisperm8-test-instance", isDirectory: true)
        let overrides = AppInstance.childEnvironmentOverrides(testRoot: root)
        XCTAssertEqual(overrides["HOME"], "/Users/x/.whisperm8-test-instance/home")
        XCTAssertEqual(overrides[AppInstance.claudeSecureStorageKey], "/Users/x/.whisperm8-test-instance/home/.claude")
        XCTAssertEqual(overrides[AppInstance.rootEnvironmentKey], "/Users/x/.whisperm8-test-instance")
        XCTAssertNil(overrides["CLAUDE_CONFIG_DIR"], "Claudes Konfigurationsordner bleibt $HOME/.claude")
        XCTAssertTrue(AppInstance.childEnvironmentOverrides(testRoot: nil).isEmpty, "Normalbetrieb unverändert")
    }

    /// Review WM8-63: Claude zieht CLAUDE_SECURESTORAGE_CONFIG_DIR vor; ein
    /// Profil der Test-Instanz braucht deshalb beide mit demselben Wert.
    func testProfileLaunchesCarryTheirOwnKeychainFolderInTheTestInstance() {
        let root = URL(fileURLWithPath: "/Users/x/.whisperm8-test-instance", isDirectory: true)
        XCTAssertEqual(AppInstance.claudeConfigEnvironment("/p/ai", testRoot: nil), ["CLAUDE_CONFIG_DIR": "/p/ai"],
                       "Normalbetrieb unverändert")
        XCTAssertEqual(AppInstance.claudeConfigEnvironment("/p/ai", testRoot: root),
                       ["CLAUDE_CONFIG_DIR": "/p/ai", AppInstance.claudeSecureStorageKey: "/p/ai"])
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
