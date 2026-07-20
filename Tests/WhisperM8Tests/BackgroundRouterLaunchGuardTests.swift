import XCTest
@testable import WhisperM8

final class BackgroundRouterLaunchGuardTests: XCTestCase {
    func testDisabledBackendSkipsEnsureAndEnvironment() {
        var ensureCalls = 0
        let environment = BackgroundRouterLaunchGuard.resolveEnvironment(
            isEnabled: { false },
            port: { 18_765 },
            ensureRunning: { _ in ensureCalls += 1; return true },
            makeEnvironment: { ["PORT": String($0)] },
            onUnavailable: {}
        )
        XCTAssertNil(environment)
        XCTAssertEqual(ensureCalls, 0)
    }

    func testEnabledReadyBackendBuildsEnvironmentFromFreshPort() {
        var ports = [18_765, 19_001]
        var ensuredPorts: [Int] = []
        let environment = BackgroundRouterLaunchGuard.resolveEnvironment(
            isEnabled: { true },
            port: { ports.removeFirst() },
            ensureRunning: { ensuredPorts.append($0); return true },
            makeEnvironment: { ["PORT": String($0)] },
            onUnavailable: {}
        )
        XCTAssertEqual(environment, ["PORT": "19001"])
        XCTAssertEqual(ensuredPorts, [18_765, 19_001])
    }

    func testEnsureFailureFallsBackWithoutRouterAndLogs() {
        var unavailableLogs = 0
        let environment = BackgroundRouterLaunchGuard.resolveEnvironment(
            isEnabled: { true },
            port: { 18_765 },
            ensureRunning: { _ in false },
            makeEnvironment: { ["PORT": String($0)] },
            onUnavailable: { unavailableLogs += 1 }
        )
        XCTAssertNil(environment)
        XCTAssertEqual(unavailableLogs, 1)
    }

    func testFreshToggleReadWinsWhenBackendIsDisabledDuringGuard() {
        var states = [true, false]
        var environmentBuilds = 0
        let environment = BackgroundRouterLaunchGuard.resolveEnvironment(
            isEnabled: { states.removeFirst() },
            port: { 18_765 },
            ensureRunning: { _ in true },
            makeEnvironment: { environmentBuilds += 1; return ["PORT": String($0)] },
            onUnavailable: {}
        )
        XCTAssertNil(environment)
        XCTAssertEqual(environmentBuilds, 0)
    }
}
