import XCTest

@testable import WhisperM8

/// Tests für die Ein-Klick-Einrichtung des GPT-Backends: sequenzielle
/// Schritte Binary → Proxy/Router → Auth mit Abbruch beim ersten Fehler
/// und `needsDeviceLogin` als explizitem Zwischenergebnis.
final class GPTBackendSetupRunnerTests: XCTestCase {
    private typealias Step = GPTBackendSetupRunner.Step
    private typealias StepState = GPTBackendSetupRunner.StepState

    private enum TestError: Error, LocalizedError {
        case downloadBlocked
        var errorDescription: String? { "Download blockiert (Test)" }
    }

    private func makeRunner(
        binary: String? = "/usr/local/bin/claude-code-proxy",
        proxy: Result<Void, ClaudeCodeProxyError> = .success(()),
        auth: ClaudeCodeProxyAuthStatus = .authenticated(account: "user@example.com", expires: "2026-08-01")
    ) -> GPTBackendSetupRunner {
        var runner = GPTBackendSetupRunner()
        runner.binaryResolver = { binary }
        // Tests dürfen nie den echten Managed Download treffen.
        runner.binaryInstaller = { throw TestError.downloadBlocked }
        runner.proxyStarter = { _ in proxy }
        runner.authChecker = { auth }
        return runner
    }

    private func collect(
        _ runner: GPTBackendSetupRunner,
        port: Int = 18_765
    ) async -> (GPTBackendSetupRunner.Outcome, [(Step, StepState)]) {
        var events: [(Step, StepState)] = []
        let outcome = await runner.run(port: port) { step, state in
            events.append((step, state))
        }
        return (outcome, events)
    }

    func testHappyPathRunsAllStepsAndEndsReady() async {
        let (outcome, events) = await collect(makeRunner())

        XCTAssertEqual(outcome, .ready)
        XCTAssertEqual(events.map(\.0), [.binary, .binary, .proxy, .proxy, .auth, .auth])
        XCTAssertEqual(events[1].1, .ok("/usr/local/bin/claude-code-proxy"))
        XCTAssertEqual(events[3].1, .ok("Erreichbar auf Port 18765"))
        guard case .ok(let authDetail) = events[5].1 else {
            return XCTFail("Auth-Schritt muss ok sein")
        }
        XCTAssertTrue(authDetail.contains("user@example.com"))
    }

    func testMissingBinaryFallsBackToManagedInstall() async {
        var installerCalled = false
        var runner = makeRunner(binary: nil)
        runner.binaryInstaller = {
            installerCalled = true
            return "/managed/bin/claude-code-proxy"
        }

        let (outcome, events) = await collect(runner)

        XCTAssertEqual(outcome, .ready)
        XCTAssertTrue(installerCalled, "Fehlendes Binary muss den Managed Download auslösen")
        XCTAssertEqual(events[1].1, .ok("/managed/bin/claude-code-proxy"))
    }

    func testInstallerNotCalledWhenBinaryExists() async {
        var installerCalled = false
        var runner = makeRunner()
        runner.binaryInstaller = {
            installerCalled = true
            return "/managed/bin/claude-code-proxy"
        }

        _ = await collect(runner)

        XCTAssertFalse(installerCalled, "PATH-Binary hat Vorrang vor dem Managed Download")
    }

    func testInstallerFailureAbortsBeforeProxyStart() async {
        var proxyStarted = false
        var runner = makeRunner(binary: nil)
        runner.proxyStarter = { _ in
            proxyStarted = true
            return .success(())
        }

        let (outcome, events) = await collect(runner)

        XCTAssertEqual(outcome, .failed(.binary))
        XCTAssertFalse(proxyStarted, "Ohne Binary darf kein Startversuch erfolgen")
        guard case .failed(let message) = events.last?.1 else {
            return XCTFail("Letztes Event muss der Installations-Fehler sein")
        }
        XCTAssertTrue(message.contains("Download blockiert"))
    }

    func testProxyStartFailureAbortsBeforeAuthCheck() async {
        var authChecked = false
        var runner = makeRunner(proxy: .failure(.routerStartFailed("Port belegt")))
        runner.authChecker = {
            authChecked = true
            return .unknown
        }

        let (outcome, events) = await collect(runner)

        XCTAssertEqual(outcome, .failed(.proxy))
        XCTAssertFalse(authChecked, "Nach Proxy-Fehler darf kein Auth-Check laufen")
        guard case .failed(let message) = events.last?.1 else {
            return XCTFail("Letztes Event muss der Proxy-Fehler sein")
        }
        XCTAssertTrue(message.contains("Port belegt"))
    }

    func testMissingLoginYieldsNeedsDeviceLogin() async {
        let (outcome, events) = await collect(makeRunner(auth: .notAuthenticated))

        XCTAssertEqual(outcome, .needsDeviceLogin)
        guard case .failed(let message) = events.last?.1 else {
            return XCTFail("Auth-Schritt muss den fehlenden Login melden")
        }
        XCTAssertTrue(message.contains("Device-Code-Login"))
    }

    func testUnknownAuthIsAHardFailure() async {
        let (outcome, _) = await collect(makeRunner(auth: .unknown))
        XCTAssertEqual(outcome, .failed(.auth))
    }
}
