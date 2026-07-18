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
        var routerPort: Int?
        let manager = makeManager(
            reachability: { _ in true },
            launcher: { _, _, _ in
                didLaunch = true
                return Self.processHandle()
            },
            routerStarter: { port in
                routerPort = port
                return .success(())
            },
            routerPort: { 18_766 }
        )

        XCTAssertNoThrow(try manager.ensureRunning(port: 18_765).get())
        XCTAssertFalse(didLaunch)
        XCTAssertEqual(routerPort, 18_766)
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
        var didStopRouter = false
        let manager = makeManager(
            reachability: { _ in
                probes += 1
                return probes >= 3
            },
            launcher: { executable, arguments, environment in
                launch = (executable, arguments, environment)
                return Self.processHandle(terminate: { didTerminate = true })
            },
            routerStopper: { didStopRouter = true },
            environment: { ["PATH": "/login-shell/bin"] },
            retryAttempts: 2
        )

        XCTAssertNoThrow(try manager.ensureRunning(port: 19_001).get())
        XCTAssertEqual(launch?.0, "/usr/local/bin/claude-code-proxy")
        XCTAssertEqual(launch?.1, ["serve", "--no-monitor", "--port", "19001"])
        XCTAssertEqual(launch?.2, [
            "CCP_BIND_ADDRESS": "127.0.0.1",
            "PATH": "/login-shell/bin",
        ])

        manager.stopIfSelfStarted()
        XCTAssertTrue(didTerminate)
        XCTAssertTrue(didStopRouter)
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
        var terminationCount = 0
        let manager = makeManager(
            reachability: { _ in false },
            launcher: { _, _, _ in
                Self.processHandle { terminationCount += 1 }
            },
            retryAttempts: 1
        )

        assertFailure(
            manager.ensureRunning(port: 18_765),
            equals: .notReachable(port: 18_765)
        )
        XCTAssertEqual(terminationCount, 1)

        manager.stopIfSelfStarted()
        XCTAssertEqual(terminationCount, 1, "Fehlerpfad darf keinen Handle registriert lassen")
    }

    func testEnsureRunningReportsRouterStartFailureAfterReachableProxy() {
        let manager = makeManager(
            reachability: { _ in true },
            routerStarter: { _ in
                .failure(NSError(domain: "test", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "router kaputt",
                ]))
            }
        )

        assertFailure(
            manager.ensureRunning(port: 18_765),
            equals: .routerStartFailed("router kaputt")
        )
    }

    func testRouterFailureTerminatesProcessStartedBySameAttempt() {
        var probes = 0
        var terminationCount = 0
        let manager = makeManager(
            reachability: { _ in
                probes += 1
                return probes >= 2
            },
            launcher: { _, _, _ in
                Self.processHandle { terminationCount += 1 }
            },
            routerStarter: { _ in
                .failure(NSError(domain: "test", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "router kaputt",
                ]))
            },
            retryAttempts: 1
        )

        assertFailure(
            manager.ensureRunning(port: 18_765),
            equals: .routerStartFailed("router kaputt")
        )
        XCTAssertEqual(terminationCount, 1)

        manager.stopIfSelfStarted()
        XCTAssertEqual(terminationCount, 1, "Router-Fehler muss den Handle entfernen")
    }

    func testNewLaunchTerminatesPreviouslyRegisteredUnhealthyProcess() throws {
        var probeResults = [false, true, false, true]
        var firstTerminationCount = 0
        var secondTerminationCount = 0
        var launches = 0
        let manager = makeManager(
            reachability: { _ in probeResults.removeFirst() },
            launcher: { _, _, _ in
                launches += 1
                if launches == 1 {
                    return Self.processHandle { firstTerminationCount += 1 }
                }
                return Self.processHandle { secondTerminationCount += 1 }
            },
            retryAttempts: 1
        )

        try manager.ensureRunning(port: 18_765).get()
        try manager.ensureRunning(port: 18_765).get()

        XCTAssertEqual(firstTerminationCount, 1)
        XCTAssertEqual(secondTerminationCount, 0)
        manager.stopIfSelfStarted()
        XCTAssertEqual(secondTerminationCount, 1)
    }

    func testHealthProbeDecisionRequiresStatusJSONHeaderAndSignatureBody() {
        let healthyBody = Data(#"{"ok":true}"#.utf8)
        XCTAssertTrue(ClaudeCodeProxyManager.isHealthyProbeResponse(
            statusCode: 200,
            contentType: "application/json; charset=utf-8",
            body: healthyBody
        ))
        XCTAssertFalse(ClaudeCodeProxyManager.isHealthyProbeResponse(
            statusCode: 503,
            contentType: "application/json",
            body: healthyBody
        ))
        XCTAssertFalse(ClaudeCodeProxyManager.isHealthyProbeResponse(
            statusCode: 200,
            contentType: "text/plain",
            body: healthyBody
        ))
        XCTAssertFalse(ClaudeCodeProxyManager.isHealthyProbeResponse(
            statusCode: 200,
            contentType: "application/json",
            body: Data(#"{"service":"fremd"}"#.utf8)
        ))
    }

    func testEnsureRunningSyncsAgentDefinitionOnSuccess() throws {
        var syncCount = 0
        let manager = makeManager(
            reachability: { _ in true },
            agentDefinitionSyncer: { syncCount += 1 }
        )

        try manager.ensureRunning(port: 18_765).get()

        XCTAssertEqual(syncCount, 1, "Erfolgreicher Backend-Start muss die gpt-Agent-Definition abgleichen")
    }

    func testStopIfSelfStartedLeavesRouterAloneWithoutSelfStartedProxy() throws {
        var didStopRouter = false
        let manager = makeManager(
            reachability: { _ in true },
            routerStopper: { didStopRouter = true }
        )
        try manager.ensureRunning(port: 18_765).get()

        manager.stopIfSelfStarted()

        XCTAssertFalse(
            didStopRouter,
            "Externer Proxy: der Router versorgt laufende Sessions und muss weiterlaufen"
        )
    }

    func testSecondDeviceLoginTerminatesFirstProcessAndLateCompletionKeepsTracking() throws {
        let notificationCenter = NotificationCenter()
        var firstTerminated = false
        var secondTerminated = false
        var completions: [(Int32) -> Void] = []
        var launches = 0
        let manager = makeManager(
            deviceLoginLauncher: { _, _, _, _, onCompletion in
                launches += 1
                completions.append(onCompletion)
                if launches == 1 {
                    return Self.processHandle(terminate: { firstTerminated = true })
                }
                return Self.processHandle(terminate: { secondTerminated = true })
            },
            notificationCenter: notificationCenter
        )

        XCTAssertNoThrow(try manager.startDeviceLogin(
            onCodeInfo: { _ in },
            onCompletion: { _ in }
        ).get())
        XCTAssertNoThrow(try manager.startDeviceLogin(
            onCodeInfo: { _ in },
            onCompletion: { _ in }
        ).get())
        XCTAssertTrue(firstTerminated, "Zweiter Login muss den ersten Prozess beenden")

        // Spaete Completion des ERSTEN Prozesses darf das Tracking des
        // zweiten nicht loeschen — sonst wuerde der App-Quit ihn verlieren.
        completions[0](143)
        notificationCenter.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertTrue(secondTerminated)
    }

    func testRunCommandTerminatesHangingProcessAfterTimeout() throws {
        let start = Date()
        let result = try ClaudeCodeProxyManager.runCommand(
            executable: "/bin/sleep",
            arguments: ["60"],
            environment: [:],
            timeout: 0.5
        )

        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertNotEqual(result.exitCode, 0)
    }

    func testRunCommandDrainsLargeStdoutAndStderrConcurrently() throws {
        let result = try ClaudeCodeProxyManager.runCommand(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "/usr/bin/yes o | /usr/bin/head -c 200000; /usr/bin/yes e | /usr/bin/head -c 200000 >&2",
            ],
            environment: ["PATH": "/usr/bin:/bin"]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.utf8.count, 200_000)
        XCTAssertEqual(result.stderr.utf8.count, 200_000)
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

    func testDeviceCodeParserReadsVisitURLAndCodeFromFixture() {
        let fixture = "Visit: https://auth.openai.com/codex/device\nEnter code: ABCD-EFGHI"

        XCTAssertEqual(
            ClaudeCodeProxyManager.parseDeviceCodeInfo(fixture),
            ClaudeCodeProxyDeviceCodeInfo(
                visitURL: "https://auth.openai.com/codex/device",
                code: "ABCD-EFGHI"
            )
        )
    }

    func testDeviceLoginStartsExpectedCommandAndForwardsParsedCodeInfo() {
        var invocation: (String, [String], [String: String])?
        var codeInfo: ClaudeCodeProxyDeviceCodeInfo?
        var completionCode: Int32?
        let manager = makeManager(
            deviceLoginLauncher: { executable, arguments, environment, onOutput, onCompletion in
                invocation = (executable, arguments, environment)
                onOutput("Visit: https://auth.openai.com/codex/device\n")
                onOutput("Enter code: ABCD-EFGHI\n")
                onCompletion(0)
                return Self.processHandle()
            },
            environment: { ["PATH": "/login-shell/bin"] }
        )

        XCTAssertNoThrow(try manager.startDeviceLogin(
            onCodeInfo: { codeInfo = $0 },
            onCompletion: { completionCode = $0 }
        ).get())
        XCTAssertEqual(invocation?.0, "/usr/local/bin/claude-code-proxy")
        XCTAssertEqual(invocation?.1, ["codex", "auth", "device"])
        XCTAssertEqual(invocation?.2, ["PATH": "/login-shell/bin"])
        XCTAssertEqual(
            codeInfo,
            ClaudeCodeProxyDeviceCodeInfo(
                visitURL: "https://auth.openai.com/codex/device",
                code: "ABCD-EFGHI"
            )
        )
        XCTAssertEqual(completionCode, 0)
    }

    private func makeManager(
        commandResolver: @escaping (String) -> String? = { _ in "/usr/local/bin/claude-code-proxy" },
        reachability: @escaping (Int) -> Bool = { _ in false },
        launcher: @escaping ClaudeCodeProxyManager.ProcessLauncher = { _, _, _ in processHandle() },
        commandRunner: @escaping ClaudeCodeProxyManager.CommandRunner = { _, _, _ in
            ClaudeCodeProxyCommandResult(exitCode: 1, stdout: "", stderr: "")
        },
        deviceLoginLauncher: @escaping ClaudeCodeProxyManager.DeviceLoginLauncher = { _, _, _, _, _ in
            processHandle()
        },
        routerStarter: @escaping ClaudeCodeProxyManager.RouterStarter = { _ in .success(()) },
        routerStopper: @escaping ClaudeCodeProxyManager.RouterStopper = {},
        routerPort: @escaping () -> Int = { 18_766 },
        agentDefinitionSyncer: @escaping () -> Void = {},
        environment: @escaping () -> [String: String] = { [:] },
        retryAttempts: Int = 1,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> ClaudeCodeProxyManager {
        ClaudeCodeProxyManager(
            commandResolver: commandResolver,
            reachabilityResolver: reachability,
            processLauncher: launcher,
            commandRunner: commandRunner,
            deviceLoginLauncher: deviceLoginLauncher,
            routerStarter: routerStarter,
            routerStopper: routerStopper,
            routerPortResolver: routerPort,
            agentDefinitionSyncer: agentDefinitionSyncer,
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
