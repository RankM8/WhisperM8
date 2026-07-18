import AppKit
import Foundation
import XCTest
@testable import WhisperM8

final class ClaudeCodeProxyManagerTests: XCTestCase {
    func testReachabilityUsesInjectedProbe() {
        var receivedPort: Int?
        let manager = makeManager(reachability: { port in
            receivedPort = port
            return true
        })

        XCTAssertTrue(manager.isReachable(port: 18_765))
        XCTAssertEqual(receivedPort, 18_765)
    }

    func testEnsureRunningReturnsImmediatelyForReachableProxy() {
        var didLaunch = false
        let manager = makeManager(
            reachability: { _ in true },
            launcher: { _, _, _ in
                didLaunch = true
                return Self.processHandle()
            }
        )

        XCTAssertNoThrow(try manager.ensureRunning(port: 18_765).get())
        XCTAssertFalse(didLaunch)
    }

    func testEnsureRunningReportsMissingBinary() {
        let manager = makeManager(
            commandResolver: { _ in nil },
            reachability: { _ in false }
        )

        assertFailure(manager.ensureRunning(port: 18_765), equals: .binaryMissing)
    }

    func testEnsureRunningLaunchesExpectedCommandAndStopsSelfStartedProcess() {
        var probes = 0
        var launch: (String, [String], [String: String])?
        var didTerminate = false
        let manager = makeManager(
            reachability: { _ in
                probes += 1
                return probes >= 3
            },
            launcher: { executable, arguments, environment in
                launch = (executable, arguments, environment)
                return Self.processHandle(terminate: { didTerminate = true })
            },
            environment: { ["PATH": "/login-shell/bin"] },
            retryAttempts: 2
        )

        XCTAssertNoThrow(try manager.ensureRunning(port: 19_001).get())
        XCTAssertEqual(launch?.0, "/usr/local/bin/claude-code-proxy")
        XCTAssertEqual(launch?.1, ["serve", "--no-monitor", "--port", "19001"])
        XCTAssertEqual(launch?.2, ["PATH": "/login-shell/bin"])

        manager.stopIfSelfStarted()
        XCTAssertTrue(didTerminate)
    }

    func testEnsureRunningReportsLaunchFailure() {
        let manager = makeManager(
            reachability: { _ in false },
            launcher: { _, _, _ in
                throw NSError(domain: "test", code: 7, userInfo: [
                    NSLocalizedDescriptionKey: "kaputt",
                ])
            }
        )

        assertFailure(
            manager.ensureRunning(port: 18_765),
            equals: .startFailed("kaputt")
        )
    }

    func testEnsureRunningReportsProxyThatNeverBecomesReachable() {
        let manager = makeManager(
            reachability: { _ in false },
            retryAttempts: 1
        )

        assertFailure(
            manager.ensureRunning(port: 18_765),
            equals: .notReachable(port: 18_765)
        )
    }

    func testWillTerminateStopsOnlySelfStartedProxy() throws {
        let notificationCenter = NotificationCenter()
        var didTerminate = false
        let manager = makeManager(
            reachability: { _ in false },
            launcher: { _, _, _ in
                Self.processHandle(terminate: { didTerminate = true })
            },
            retryAttempts: 0,
            notificationCenter: notificationCenter
        )
        _ = manager.ensureRunning(port: 18_765)

        notificationCenter.post(name: NSApplication.willTerminateNotification, object: nil)

        XCTAssertTrue(didTerminate)
    }

    func testAuthStatusRunsExpectedCommandThroughInjectedRunner() {
        var invocation: (String, [String], [String: String])?
        let manager = makeManager(
            commandRunner: { executable, arguments, environment in
                invocation = (executable, arguments, environment)
                return ClaudeCodeProxyCommandResult(
                    exitCode: 0,
                    stdout: "Account: user@example.com\nExpires: 2026-08-01T12:00:00Z\n",
                    stderr: ""
                )
            },
            environment: { ["PATH": "/login-shell/bin"] }
        )

        XCTAssertEqual(
            manager.authStatus(),
            .authenticated(account: "user@example.com", expires: "2026-08-01T12:00:00Z")
        )
        XCTAssertEqual(invocation?.0, "/usr/local/bin/claude-code-proxy")
        XCTAssertEqual(invocation?.1, ["codex", "auth", "status"])
        XCTAssertEqual(invocation?.2, ["PATH": "/login-shell/bin"])
    }

    func testAuthStatusParserRecognizesAuthenticatedOutput() {
        XCTAssertEqual(
            ClaudeCodeProxyManager.parseAuthStatus(
                "Codex authentication\nAccount: account-123\nExpires: 2026-08-01T12:00:00Z\n"
            ),
            .authenticated(account: "account-123", expires: "2026-08-01T12:00:00Z")
        )
    }

    func testAuthStatusParserRecognizesMissingAuthentication() {
        XCTAssertEqual(
            ClaudeCodeProxyManager.parseAuthStatus("Not authenticated. Run codex auth login."),
            .notAuthenticated
        )
    }

    func testAuthStatusParserRejectsGarbage() {
        XCTAssertEqual(ClaudeCodeProxyManager.parseAuthStatus("alles kaputt"), .unknown)
    }

    private func makeManager(
        commandResolver: @escaping (String) -> String? = { _ in "/usr/local/bin/claude-code-proxy" },
        reachability: @escaping (Int) -> Bool = { _ in false },
        launcher: @escaping ClaudeCodeProxyManager.ProcessLauncher = { _, _, _ in processHandle() },
        commandRunner: @escaping ClaudeCodeProxyManager.CommandRunner = { _, _, _ in
            ClaudeCodeProxyCommandResult(exitCode: 1, stdout: "", stderr: "")
        },
        environment: @escaping () -> [String: String] = { [:] },
        retryAttempts: Int = 1,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> ClaudeCodeProxyManager {
        ClaudeCodeProxyManager(
            commandResolver: commandResolver,
            reachabilityResolver: reachability,
            processLauncher: launcher,
            commandRunner: commandRunner,
            environmentResolver: environment,
            sleepResolver: { _ in },
            retryAttempts: retryAttempts,
            retryDelay: 0,
            notificationCenter: notificationCenter
        )
    }

    private static func processHandle(
        terminate: @escaping () -> Void = {}
    ) -> ClaudeCodeProxyProcessHandle {
        ClaudeCodeProxyProcessHandle(isRunning: { true }, terminate: terminate)
    }

    private func assertFailure(
        _ result: Result<Void, ClaudeCodeProxyError>,
        equals expected: ClaudeCodeProxyError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success:
            XCTFail("Erwarteter Fehler blieb aus", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }
}
