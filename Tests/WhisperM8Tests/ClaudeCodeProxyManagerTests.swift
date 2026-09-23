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
            environment: {
                [
                    "PATH": "/login-shell/bin",
                    "CCP_CODEX_SERVICE_TIER": "priority",
                ]
            },
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
        manager.storedAccountIDResolver = { _ in "user@example.com" }

        XCTAssertEqual(
            manager.authStatus(),
            .authenticated(account: "user@example.com", expires: "2026-08-01T12:00:00Z")
        )
        XCTAssertEqual(invocation?.0, "/usr/local/bin/claude-code-proxy")
        XCTAssertEqual(invocation?.1, ["codex", "auth", "status"])
        XCTAssertEqual(invocation?.2, ["PATH": "/login-shell/bin"])
    }

    // MARK: - GPT-Konto-Profile (CCP_CONFIG_DIR)

    func testAuthStatusForProfileInjectsConfigDirAndStripsInheritedOne() {
        var invocation: (String, [String], [String: String])?
        let manager = makeManager(
            commandRunner: { executable, arguments, environment in
                invocation = (executable, arguments, environment)
                return ClaudeCodeProxyCommandResult(
                    exitCode: 0,
                    stdout: "Account: acct-zweit\nExpires: 2026-10-01T00:00:00Z\n",
                    stderr: ""
                )
            },
            // Geerbtes CCP_CONFIG_DIR aus der Login-Shell darf nie gewinnen.
            environment: { ["PATH": "/login-shell/bin", "CCP_CONFIG_DIR": "/geerbt"] }
        )
        manager.profileEnvironmentResolver = { profile in
            profile == "zweit" ? ["CCP_CONFIG_DIR": "/profiles/zweit"] : [:]
        }
        manager.storedAccountIDResolver = { _ in "acct-zweit" }

        XCTAssertEqual(
            manager.authStatus(profile: "zweit"),
            .authenticated(account: "acct-zweit", expires: "2026-10-01T00:00:00Z")
        )
        XCTAssertEqual(invocation?.1, ["codex", "auth", "status"])
        XCTAssertEqual(invocation?.2, ["PATH": "/login-shell/bin", "CCP_CONFIG_DIR": "/profiles/zweit"])
    }

    func testAuthStatusForMainRemovesInheritedConfigDir() {
        var environment: [String: String]?
        let manager = makeManager(
            commandRunner: { _, _, env in
                environment = env
                return ClaudeCodeProxyCommandResult(exitCode: 0, stdout: "Not authenticated", stderr: "")
            },
            environment: { ["PATH": "/bin", "CCP_CONFIG_DIR": "/geerbt"] }
        )
        manager.profileEnvironmentResolver = { _ in [:] }
        manager.storedAccountIDResolver = { _ in "acct-main" }

        XCTAssertEqual(manager.authStatus(profile: nil), .notAuthenticated)
        XCTAssertEqual(environment, ["PATH": "/bin"])
    }

    func testAuthStatusForMainAppliesFallbackGuardWhenProfilesEnabled() {
        // main laeuft im Datei-Modus → ohne eigene Datei meldet der Proxy still
        // das Codex-CLI-Konto. Das darf nicht als „angemeldet" durchgehen.
        var didRunAuth = false
        let manager = makeManager(
            commandRunner: { _, arguments, _ in
                if arguments == ["codex", "auth", "status"] { didRunAuth = true }
                return ClaudeCodeProxyCommandResult(exitCode: 0, stdout: "Account: cli-konto\nExpires: x\n", stderr: "")
            }
        )
        manager.profilesEnabledResolver = { true }
        manager.storedAccountIDResolver = { _ in nil }
        XCTAssertEqual(manager.authStatus(profile: nil), .notAuthenticated)
        XCTAssertFalse(didRunAuth)

        // Datei da, Proxy meldet ein anderes Konto → ebenfalls nicht angemeldet.
        manager.storedAccountIDResolver = { _ in "acct-main" }
        XCTAssertEqual(manager.authStatus(profile: nil), .notAuthenticated)

        // Kill-Switch aus → Proxy-Meldung fuer main gilt unveraendert.
        manager.profilesEnabledResolver = { false }
        manager.storedAccountIDResolver = { _ in nil }
        XCTAssertEqual(manager.authStatus(profile: nil), .authenticated(account: "cli-konto", expires: "x"))
    }

    func testStopIfSelfStartedAlsoStopsProfileInstances() throws {
        var terminations = 0
        let manager = makeManager(
            reachability: { _ in terminations == 0 },
            launcher: { _, _, _ in Self.processHandle { terminations += 1 } },
            retryAttempts: 1
        )
        manager.mainPortResolver = { 18_765 }
        manager.portAvailabilityResolver = { _ in true }
        manager.profileEnvironmentResolver = { _ in ["CCP_CONFIG_DIR": "/p"] }
        manager.storedAccountIDResolver = { _ in "acct" }
        try manager.ensureRunning(profile: "zweit").get()

        manager.stopIfSelfStarted()

        XCTAssertEqual(terminations, 1)
        XCTAssertTrue(manager.runningProfileInstances().isEmpty)
    }

    func testEnsureRunningProfileRelaunchesDeadInstance() throws {
        var firstDied = false
        var launches = 0
        let manager = makeManager(
            reachability: { _ in launches > 0 && !(launches == 1 && firstDied) },
            launcher: { _, _, _ in
                launches += 1
                let index = launches
                return ClaudeCodeProxyProcessHandle(
                    isRunning: { index == 1 ? !firstDied : true },
                    terminate: {}
                )
            },
            retryAttempts: 1
        )
        manager.mainPortResolver = { 18_765 }
        manager.portAvailabilityResolver = { _ in true }
        manager.profileEnvironmentResolver = { _ in ["CCP_CONFIG_DIR": "/p"] }
        manager.storedAccountIDResolver = { _ in "acct" }

        try manager.ensureRunning(profile: "zweit").get()
        firstDied = true
        XCTAssertNil(manager.port(forProfile: "zweit"), "tote Instanz darf nicht als Ziel gelten")
        try manager.ensureRunning(profile: "zweit").get()
        XCTAssertEqual(launches, 2)
        XCTAssertEqual(manager.runningProfileInstances().count, 1)
        XCTAssertNotNil(manager.port(forProfile: "zweit"))
    }

    func testStartInstanceInBackgroundLaunchesOncePerProfileWhileStarting() throws {
        let launched = expectation(description: "launch")
        launched.assertForOverFulfill = false
        var launches = 0
        let manager = makeManager(
            reachability: { _ in launches > 0 },
            launcher: { _, _, _ in
                launches += 1
                launched.fulfill()
                return Self.processHandle()
            },
            retryAttempts: 1
        )
        manager.mainPortResolver = { 18_765 }
        manager.portAvailabilityResolver = { _ in true }
        manager.profileEnvironmentResolver = { _ in ["CCP_CONFIG_DIR": "/p"] }
        manager.storedAccountIDResolver = { _ in "acct" }

        manager.startInstanceInBackground(profile: "zweit")
        manager.startInstanceInBackground(profile: "zweit")
        manager.startInstanceInBackground(profile: "zweit")
        wait(for: [launched], timeout: 2)
        // Kurz warten, bis der Hintergrund-Task die Registry geschrieben hat.
        let registered = expectation(description: "registered")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { registered.fulfill() }
        wait(for: [registered], timeout: 2)
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(manager.port(forProfile: "zweit"), 18_775)
    }

    func testAuthStatusForProfileWithoutOwnAuthFileNeverRunsCommand() {
        // Fallback-Falle: ohne eigene Datei meldet der Proxy still das
        // Standardkonto — der Befehl darf gar nicht erst laufen.
        // Der Runner sieht auch den `--version`-Aufruf der Binary-Auswahl —
        // gezaehlt wird deshalb nur der Auth-Befehl selbst.
        var didRun = false
        let manager = makeManager(
            commandRunner: { _, arguments, _ in
                if arguments == ["codex", "auth", "status"] { didRun = true }
                return ClaudeCodeProxyCommandResult(exitCode: 0, stdout: "Account: fremd\nExpires: x\n", stderr: "")
            }
        )
        manager.profileEnvironmentResolver = { _ in ["CCP_CONFIG_DIR": "/profiles/leer"] }
        manager.storedAccountIDResolver = { _ in nil }

        XCTAssertEqual(manager.authStatus(profile: "leer"), .notAuthenticated)
        XCTAssertFalse(didRun)
    }

    func testAuthStatusForProfileRejectsForeignAccountReportedByProxy() {
        let manager = makeManager(
            commandRunner: { _, _, _ in
                ClaudeCodeProxyCommandResult(
                    exitCode: 0,
                    stdout: "Account: acct-default\nExpires: 2026-10-01T00:00:00Z\n",
                    stderr: ""
                )
            }
        )
        manager.profileEnvironmentResolver = { _ in ["CCP_CONFIG_DIR": "/profiles/zweit"] }
        manager.storedAccountIDResolver = { _ in "acct-zweit" }

        XCTAssertEqual(manager.authStatus(profile: "zweit"), .notAuthenticated)
    }

    func testReconcileAuthStatusPureDecision() {
        let authenticated = ClaudeCodeProxyAuthStatus.authenticated(account: "a", expires: "e")
        // main: Meldung des Proxys gilt unveraendert.
        XCTAssertEqual(
            ClaudeCodeProxyManager.reconcileAuthStatus(authenticated, storedAccountID: nil, isMain: true),
            authenticated
        )
        // Zusatzprofil: nur bei uebereinstimmender ID angemeldet.
        XCTAssertEqual(
            ClaudeCodeProxyManager.reconcileAuthStatus(authenticated, storedAccountID: "a", isMain: false),
            authenticated
        )
        XCTAssertEqual(
            ClaudeCodeProxyManager.reconcileAuthStatus(authenticated, storedAccountID: "b", isMain: false),
            .notAuthenticated
        )
        XCTAssertEqual(
            ClaudeCodeProxyManager.reconcileAuthStatus(authenticated, storedAccountID: nil, isMain: false),
            .notAuthenticated
        )
        // Nicht-angemeldet und unbekannt bleiben, was sie sind.
        XCTAssertEqual(
            ClaudeCodeProxyManager.reconcileAuthStatus(.notAuthenticated, storedAccountID: "a", isMain: false),
            .notAuthenticated
        )
        XCTAssertEqual(
            ClaudeCodeProxyManager.reconcileAuthStatus(.unknown, storedAccountID: "a", isMain: false),
            .unknown
        )
        XCTAssertTrue(ClaudeCodeProxyManager.isMainProfile(nil))
        XCTAssertTrue(ClaudeCodeProxyManager.isMainProfile("main"))
        XCTAssertTrue(ClaudeCodeProxyManager.isMainProfile(" "))
        XCTAssertFalse(ClaudeCodeProxyManager.isMainProfile("zweit"))
    }

    func testDeviceLoginForProfileInjectsConfigDir() throws {
        var launch: (String, [String], [String: String])?
        let manager = makeManager(
            deviceLoginLauncher: { executable, arguments, environment, _, _ in
                launch = (executable, arguments, environment)
                return Self.processHandle()
            },
            environment: { ["PATH": "/bin", "CCP_CONFIG_DIR": "/geerbt"] }
        )
        manager.profileEnvironmentResolver = { profile in
            profile == "zweit" ? ["CCP_CONFIG_DIR": "/profiles/zweit"] : [:]
        }

        XCTAssertNoThrow(
            try manager.startDeviceLogin(profile: "zweit", onCodeInfo: { _ in }, onCompletion: { _ in }).get()
        )
        XCTAssertEqual(launch?.1, ["codex", "auth", "device"])
        XCTAssertEqual(launch?.2, ["PATH": "/bin", "CCP_CONFIG_DIR": "/profiles/zweit"])
    }

    func testMainStartCarriesConfigDirFromResolver() throws {
        var launch: [String: String]?
        let manager = makeManager(
            reachability: { _ in launch != nil },
            launcher: { _, _, environment in
                launch = environment
                return Self.processHandle()
            },
            environment: { ["PATH": "/bin"] },
            retryAttempts: 1
        )
        manager.profileEnvironmentResolver = { profile in
            profile == nil ? ["CCP_CONFIG_DIR": "/Users/x/.config/claude-code-proxy"] : [:]
        }

        try manager.ensureRunning(port: 18_765).get()
        XCTAssertEqual(launch, [
            "PATH": "/bin",
            "CCP_CONFIG_DIR": "/Users/x/.config/claude-code-proxy",
            "CCP_BIND_ADDRESS": "127.0.0.1",
        ])
    }

    func testEnsureRunningProfileLaunchesInstanceWithConfigDirAndOwnPort() throws {
        var launch: (String, [String], [String: String])?
        var routerStarts = 0
        let manager = makeManager(
            reachability: { port in port == 18_775 && launch != nil },
            launcher: { executable, arguments, environment in
                launch = (executable, arguments, environment)
                return Self.processHandle()
            },
            routerStarter: { _ in
                routerStarts += 1
                return .success(())
            },
            environment: { ["PATH": "/bin", "CCP_CONFIG_DIR": "/geerbt", "CCP_CODEX_SERVICE_TIER": "priority"] },
            retryAttempts: 2
        )
        manager.profilesEnabledResolver = { true }
        manager.mainPortResolver = { 18_765 }
        manager.portAvailabilityResolver = { _ in true }
        manager.profileEnvironmentResolver = { _ in ["CCP_CONFIG_DIR": "/profiles/zweit"] }
        manager.storedAccountIDResolver = { _ in "acct-zweit" }

        XCTAssertNoThrow(try manager.ensureRunning(profile: "zweit").get())
        XCTAssertEqual(launch?.1, ["serve", "--no-monitor", "--port", "18775"])
        XCTAssertEqual(launch?.2, [
            "PATH": "/bin",
            "CCP_CONFIG_DIR": "/profiles/zweit",
            "CCP_BIND_ADDRESS": "127.0.0.1",
        ])
        XCTAssertEqual(manager.port(forProfile: "zweit"), 18_775)
        XCTAssertEqual(manager.port(forProfile: nil), 18_765)
        XCTAssertEqual(manager.runningProfileInstances(), ["zweit": 18_775])
        XCTAssertEqual(routerStarts, 1)
    }

    func testEnsureRunningProfileReusesHealthyInstance() throws {
        var launches = 0
        let manager = makeManager(
            reachability: { _ in launches > 0 },
            launcher: { _, _, _ in
                launches += 1
                return Self.processHandle()
            },
            retryAttempts: 1
        )
        manager.profilesEnabledResolver = { true }
        manager.mainPortResolver = { 18_765 }
        manager.portAvailabilityResolver = { _ in true }
        manager.profileEnvironmentResolver = { _ in ["CCP_CONFIG_DIR": "/profiles/zweit"] }
        manager.storedAccountIDResolver = { _ in "acct-zweit" }

        try manager.ensureRunning(profile: "zweit").get()
        try manager.ensureRunning(profile: "zweit").get()
        XCTAssertEqual(launches, 1)
    }

    func testEnsureRunningProfileRefusesWithoutOwnLogin() {
        var didLaunch = false
        let manager = makeManager(
            reachability: { _ in false },
            launcher: { _, _, _ in
                didLaunch = true
                return Self.processHandle()
            }
        )
        manager.profilesEnabledResolver = { true }
        manager.profileEnvironmentResolver = { _ in ["CCP_CONFIG_DIR": "/profiles/leer"] }
        manager.storedAccountIDResolver = { _ in nil }

        assertFailure(manager.ensureRunning(profile: "leer"), equals: .profileNotLoggedIn("leer"))
        XCTAssertFalse(didLaunch, "ohne eigene Auth-Datei darf keine Instanz starten (stiller Fallback)")
        XCTAssertNil(manager.port(forProfile: "leer"))
    }

    func testEnsureRunningProfileFallsBackToMainPathWhenProfilesDisabled() throws {
        var launch: [String]?
        let manager = makeManager(
            reachability: { _ in launch != nil },
            launcher: { _, arguments, _ in
                launch = arguments
                return Self.processHandle()
            },
            retryAttempts: 1
        )
        manager.profilesEnabledResolver = { false }
        manager.mainPortResolver = { 18_765 }
        manager.storedAccountIDResolver = { _ in "acct-zweit" }

        try manager.ensureRunning(profile: "zweit").get()
        XCTAssertEqual(launch, ["serve", "--no-monitor", "--port", "18765"])
        XCTAssertEqual(manager.port(forProfile: "zweit"), 18_765)
    }

    func testProfilePortAllocationSkipsTakenPorts() throws {
        var launchedPorts: [String] = []
        let manager = makeManager(
            reachability: { _ in !launchedPorts.isEmpty },
            launcher: { _, arguments, _ in
                launchedPorts.append(arguments.last ?? "")
                return Self.processHandle()
            },
            retryAttempts: 1
        )
        manager.profilesEnabledResolver = { true }
        manager.mainPortResolver = { 18_765 }
        manager.portAvailabilityResolver = { port in port != 18_775 }
        manager.profileEnvironmentResolver = { _ in ["CCP_CONFIG_DIR": "/profiles/x"] }
        manager.storedAccountIDResolver = { _ in "acct" }

        try manager.ensureRunning(profile: "zweit").get()
        XCTAssertEqual(launchedPorts, ["18776"])
    }

    func testStopAllProfileInstancesTerminatesEveryInstance() throws {
        var terminations = 0
        let manager = makeManager(
            reachability: { _ in terminations == 0 },
            launcher: { _, _, _ in Self.processHandle { terminations += 1 } },
            retryAttempts: 1
        )
        manager.profilesEnabledResolver = { true }
        manager.mainPortResolver = { 18_765 }
        manager.portAvailabilityResolver = { _ in true }
        manager.profileEnvironmentResolver = { _ in ["CCP_CONFIG_DIR": "/p"] }
        manager.storedAccountIDResolver = { _ in "acct" }

        try manager.ensureRunning(profile: "a").get()
        try manager.ensureRunning(profile: "b").get()
        XCTAssertEqual(manager.runningProfileInstances().count, 2)

        manager.stopAllProfileInstances()
        XCTAssertEqual(terminations, 2)
        XCTAssertTrue(manager.runningProfileInstances().isEmpty)
    }

    func testLogoutRunsCommandWithProfileConfigDirAndStopsInstance() throws {
        var terminations = 0
        var invocation: ([String], [String: String])?
        let manager = makeManager(
            reachability: { _ in true },
            launcher: { _, _, _ in Self.processHandle { terminations += 1 } },
            commandRunner: { _, arguments, environment in
                if arguments.first == "codex" { invocation = (arguments, environment) }
                return ClaudeCodeProxyCommandResult(exitCode: 0, stdout: "", stderr: "")
            },
            environment: { ["PATH": "/bin"] },
            retryAttempts: 1
        )
        manager.profilesEnabledResolver = { true }
        manager.mainPortResolver = { 18_765 }
        manager.portAvailabilityResolver = { _ in true }
        manager.profileEnvironmentResolver = { _ in ["CCP_CONFIG_DIR": "/profiles/zweit"] }
        manager.storedAccountIDResolver = { _ in "acct" }
        try manager.ensureRunning(profile: "zweit").get()

        XCTAssertNoThrow(try manager.logout(profile: "zweit").get())
        XCTAssertEqual(invocation?.0, ["codex", "auth", "logout"])
        XCTAssertEqual(invocation?.1, ["PATH": "/bin", "CCP_CONFIG_DIR": "/profiles/zweit"])
        XCTAssertEqual(terminations, 1)
        XCTAssertNil(manager.port(forProfile: "zweit"))
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

    // MARK: Binary-Auswahl (Katalog-Allowlist)

    private static let currentVersionOutput = "claude-code-proxy 0.1.42\n"
    private static let homebrewVersionOutput = "claude-code-proxy 0.1.21\n"

    /// `--version` pro Pfad beantworten; alles andere scheitert.
    private static func versionRunner(
        _ versions: [String: String],
        calls: (() -> Void)? = nil
    ) -> ClaudeCodeProxyManager.CommandRunner {
        { executable, arguments, _ in
            guard arguments == ["--version"], let output = versions[executable] else {
                return ClaudeCodeProxyCommandResult(exitCode: 1, stdout: "", stderr: "")
            }
            calls?()
            return ClaudeCodeProxyCommandResult(exitCode: 0, stdout: output, stderr: "")
        }
    }

    func testCatalogCapablePathBinaryKeepsPrecedenceOverManaged() {
        let manager = makeManager(
            commandResolver: { _ in "/opt/homebrew/bin/claude-code-proxy" },
            commandRunner: Self.versionRunner([
                "/opt/homebrew/bin/claude-code-proxy": Self.currentVersionOutput,
                "/managed/claude-code-proxy": Self.currentVersionOutput,
            ]),
            managedBinary: { "/managed/claude-code-proxy" }
        )

        let binary = manager.resolvedBinary()
        XCTAssertEqual(binary?.path, "/opt/homebrew/bin/claude-code-proxy")
        XCTAssertEqual(binary?.source, .path)
        XCTAssertEqual(binary?.version, "0.1.42")
        XCTAssertEqual(binary?.meetsMinimumVersion, true)
    }

    func testOutdatedPathBinaryYieldsToCatalogCapableManagedBinary() {
        // Vorfall 2026-09-08: Homebrew 0.1.21 (einkompilierte Liste bis
        // gpt-5.6) gewann gegen alles und lehnte gpt-6-astra ab.
        let manager = makeManager(
            commandResolver: { _ in "/opt/homebrew/bin/claude-code-proxy" },
            commandRunner: Self.versionRunner([
                "/opt/homebrew/bin/claude-code-proxy": Self.homebrewVersionOutput,
                "/managed/claude-code-proxy": Self.currentVersionOutput,
            ]),
            managedBinary: { "/managed/claude-code-proxy" }
        )

        let binary = manager.resolvedBinary()
        XCTAssertEqual(binary?.path, "/managed/claude-code-proxy")
        XCTAssertEqual(binary?.source, .managed)
        XCTAssertEqual(binary?.meetsMinimumVersion, true)
        XCTAssertEqual(manager.resolvedBinaryPath(), "/managed/claude-code-proxy")
    }

    func testOnlyOutdatedPathBinaryIsReportedAsOutdatedCandidate() {
        let manager = makeManager(
            commandResolver: { _ in "/opt/homebrew/bin/claude-code-proxy" },
            commandRunner: Self.versionRunner([
                "/opt/homebrew/bin/claude-code-proxy": Self.homebrewVersionOutput,
            ])
        )

        let binary = manager.resolvedBinary()
        XCTAssertEqual(binary?.path, "/opt/homebrew/bin/claude-code-proxy")
        XCTAssertEqual(binary?.version, "0.1.21")
        XCTAssertEqual(binary?.meetsMinimumVersion, false)
    }

    func testUnknownVersionCountsAsOutdated() {
        // Kein `--version`-Output (Default-Runner scheitert) → lieber das
        // verwaltete Binary als ein blindes.
        let manager = makeManager(
            commandResolver: { _ in "/opt/homebrew/bin/claude-code-proxy" },
            managedBinary: { "/managed/claude-code-proxy" }
        )
        // Beide unbekannt → PATH bleibt (kein Grund zu wechseln) …
        XCTAssertEqual(manager.resolvedBinary()?.path, "/opt/homebrew/bin/claude-code-proxy")
        XCTAssertEqual(manager.resolvedBinary()?.meetsMinimumVersion, false)
    }

    func testEnsureRunningInstallsManagedBinaryWhenOnlyOutdatedPathBinaryExists() {
        var installCalls = 0
        var launched: [String] = []
        var managedInstalled = false
        let manager = makeManager(
            commandResolver: { _ in "/opt/homebrew/bin/claude-code-proxy" },
            reachability: { _ in launched.isEmpty ? false : true },
            launcher: { executable, _, _ in
                launched.append(executable)
                return Self.processHandle()
            },
            commandRunner: Self.versionRunner([
                "/opt/homebrew/bin/claude-code-proxy": Self.homebrewVersionOutput,
                "/managed/claude-code-proxy": Self.currentVersionOutput,
            ]),
            managedBinary: { managedInstalled ? "/managed/claude-code-proxy" : nil },
            managedInstaller: {
                installCalls += 1
                managedInstalled = true
                return "/managed/claude-code-proxy"
            }
        )

        assertSuccess(manager.ensureRunning(port: 18_765))

        XCTAssertEqual(installCalls, 1)
        XCTAssertEqual(launched, ["/managed/claude-code-proxy"], "Nach der Installation muss das verwaltete Binary starten, nicht das alte Homebrew")
        XCTAssertNil(manager.lastManagedInstallError)
    }

    func testFailedManagedInstallFallsBackToOutdatedBinaryAndIsNotRetried() {
        var installCalls = 0
        var launched: [String] = []
        let manager = makeManager(
            commandResolver: { _ in "/opt/homebrew/bin/claude-code-proxy" },
            reachability: { _ in !launched.isEmpty },
            launcher: { executable, _, _ in
                launched.append(executable)
                return Self.processHandle()
            },
            commandRunner: Self.versionRunner([
                "/opt/homebrew/bin/claude-code-proxy": Self.homebrewVersionOutput,
            ]),
            managedInstaller: {
                installCalls += 1
                throw TestInstallError.downloadBlocked
            }
        )

        assertSuccess(manager.ensureRunning(port: 18_765))
        XCTAssertEqual(launched, ["/opt/homebrew/bin/claude-code-proxy"], "Ohne aktuelles Binary bleibt der alte Proxy besser als keiner")
        XCTAssertEqual(manager.lastManagedInstallError, "Download blockiert (Test)")

        // Zweiter Start (Proxy weg): kein erneuter Download-Versuch.
        launched.removeAll()
        manager.stopIfSelfStarted()
        assertSuccess(manager.ensureRunning(port: 18_765))
        XCTAssertEqual(installCalls, 1)
    }

    func testEnsureRunningDoesNotInstallWhenPathBinaryIsCatalogCapable() {
        var installCalls = 0
        let manager = makeManager(
            commandResolver: { _ in "/opt/homebrew/bin/claude-code-proxy" },
            reachability: { _ in true },
            commandRunner: Self.versionRunner([
                "/opt/homebrew/bin/claude-code-proxy": Self.currentVersionOutput,
            ]),
            managedInstaller: {
                installCalls += 1
                return "/managed/claude-code-proxy"
            }
        )
        assertSuccess(manager.ensureRunning(port: 18_765))
        XCTAssertEqual(installCalls, 0)
    }

    func testBinaryVersionIsCachedPerPath() {
        var versionCalls = 0
        let manager = makeManager(
            commandResolver: { _ in "/opt/homebrew/bin/claude-code-proxy" },
            commandRunner: Self.versionRunner(
                ["/opt/homebrew/bin/claude-code-proxy": Self.currentVersionOutput],
                calls: { versionCalls += 1 }
            )
        )
        _ = manager.resolvedBinary()
        _ = manager.resolvedBinary()
        _ = manager.resolvedBinaryPath()
        XCTAssertEqual(versionCalls, 1, "Status-Refresh, Chat-Start und Auth-Check dürfen nicht je einen Subprozess kosten")
    }

    private enum TestInstallError: Error, LocalizedError {
        case downloadBlocked
        var errorDescription: String? { "Download blockiert (Test)" }
    }

    private func assertSuccess(
        _ result: Result<Void, ClaudeCodeProxyError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .failure(let error) = result {
            XCTFail("Erwartet Erfolg, erhalten \(error)", file: file, line: line)
        }
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
        notificationCenter: NotificationCenter = NotificationCenter(),
        managedBinary: @escaping () -> String? = { nil },
        // Tests duerfen nie den echten Managed Download treffen.
        managedInstaller: @escaping () throws -> String = { throw TestInstallError.downloadBlocked }
    ) -> ClaudeCodeProxyManager {
        let manager = ClaudeCodeProxyManager(
            commandResolver: commandResolver,
            // Kein Zugriff auf das echte Managed-Binary in App Support —
            // sonst haengt der Test am Dateisystem der Maschine.
            managedBinaryResolver: managedBinary,
            managedInstaller: managedInstaller,
            reachabilityResolver: reachability,
            processLauncher: launcher,
            commandRunner: commandRunner,
            deviceLoginLauncher: deviceLoginLauncher,
            routerStarter: routerStarter,
            routerStopper: routerStopper,
            routerPortResolver: routerPort,
            agentDefinitionSyncer: agentDefinitionSyncer,
            // Nie den echten Proxy auf 127.0.0.1 abfragen.
            modelListRefresher: { _ in },
            environmentResolver: environment,
            sleepResolver: { _ in },
            retryAttempts: retryAttempts,
            retryDelay: 0,
            notificationCenter: notificationCenter
        )
        // Tests haengen nie an den echten `~/.gpt-profiles` / Preferences.
        manager.profileEnvironmentResolver = { _ in [:] }
        manager.storedAccountIDResolver = { _ in nil }
        manager.profilesEnabledResolver = { true }
        return manager
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
