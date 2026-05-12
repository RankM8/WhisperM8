import Foundation
import XCTest
@testable import WhisperM8

final class BackgroundAgentLifecycleTests: XCTestCase {

    // MARK: - Action mapping

    func testActionSubcommandMatchesClaudeCLI() {
        XCTAssertEqual(BackgroundAgentLifecycle.Action.logs.subcommand, "logs")
        XCTAssertEqual(BackgroundAgentLifecycle.Action.stop.subcommand, "stop")
        XCTAssertEqual(BackgroundAgentLifecycle.Action.respawn.subcommand, "respawn")
        XCTAssertEqual(BackgroundAgentLifecycle.Action.rm.subcommand, "rm")
    }

    // MARK: - Successful runs

    func testLogsPassesShortIDAsArgument() async throws {
        let runner = SpyProcessRunner(result: ProcessRunResult(
            exitCode: 0,
            stdout: "session output\n",
            stderr: ""
        ))
        let result = try await BackgroundAgentLifecycle.logs(
            shortID: "7c5dcf5d",
            commandResolver: { _ in "/usr/local/bin/claude" },
            processRunner: runner
        )
        XCTAssertEqual(result.stdout, "session output\n")
        XCTAssertEqual(runner.recordedArguments, ["logs", "7c5dcf5d"])
        XCTAssertEqual(runner.recordedExecutable, "/usr/local/bin/claude")
    }

    func testStopPassesShortIDAsArgument() async throws {
        let runner = SpyProcessRunner(result: ProcessRunResult(
            exitCode: 0,
            stdout: "stopped\n",
            stderr: ""
        ))
        _ = try await BackgroundAgentLifecycle.stop(
            shortID: "deadbeef",
            commandResolver: { _ in "/usr/local/bin/claude" },
            processRunner: runner
        )
        XCTAssertEqual(runner.recordedArguments, ["stop", "deadbeef"])
    }

    func testRespawnPassesShortIDAsArgument() async throws {
        let runner = SpyProcessRunner(result: ProcessRunResult(
            exitCode: 0,
            stdout: "respawned · deadbeef\n",
            stderr: ""
        ))
        _ = try await BackgroundAgentLifecycle.respawn(
            shortID: "deadbeef",
            commandResolver: { _ in "/usr/local/bin/claude" },
            processRunner: runner
        )
        XCTAssertEqual(runner.recordedArguments, ["respawn", "deadbeef"])
    }

    func testRemovePassesShortIDAsArgument() async throws {
        let runner = SpyProcessRunner(result: ProcessRunResult(
            exitCode: 0,
            stdout: "",
            stderr: ""
        ))
        _ = try await BackgroundAgentLifecycle.remove(
            shortID: "abc12345",
            commandResolver: { _ in "/usr/local/bin/claude" },
            processRunner: runner
        )
        XCTAssertEqual(runner.recordedArguments, ["rm", "abc12345"])
    }

    func testLifecycleTrimsWhitespaceFromShortID() async throws {
        let runner = SpyProcessRunner(result: ProcessRunResult(
            exitCode: 0,
            stdout: "",
            stderr: ""
        ))
        _ = try await BackgroundAgentLifecycle.logs(
            shortID: "  cafebabe  ",
            commandResolver: { _ in "/usr/local/bin/claude" },
            processRunner: runner
        )
        XCTAssertEqual(runner.recordedArguments, ["logs", "cafebabe"])
    }

    // MARK: - Error paths

    func testThrowsWhenClaudeNotFound() async {
        let runner = SpyProcessRunner(result: ProcessRunResult(exitCode: 0, stdout: "", stderr: ""))
        do {
            _ = try await BackgroundAgentLifecycle.stop(
                shortID: "7c5dcf5d",
                commandResolver: { _ in nil },
                processRunner: runner
            )
            XCTFail("expected LifecycleError.claudeNotFound")
        } catch BackgroundAgentLifecycle.LifecycleError.claudeNotFound {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testThrowsWhenShortIDIsEmpty() async {
        let runner = SpyProcessRunner(result: ProcessRunResult(exitCode: 0, stdout: "", stderr: ""))
        do {
            _ = try await BackgroundAgentLifecycle.stop(
                shortID: "   ",
                commandResolver: { _ in "/usr/local/bin/claude" },
                processRunner: runner
            )
            XCTFail("expected LifecycleError.shortIDEmpty")
        } catch BackgroundAgentLifecycle.LifecycleError.shortIDEmpty {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testThrowsNonZeroExitWithStderr() async {
        let runner = SpyProcessRunner(result: ProcessRunResult(
            exitCode: 2,
            stdout: "",
            stderr: "Background agents are disabled by managed setting"
        ))
        do {
            _ = try await BackgroundAgentLifecycle.stop(
                shortID: "7c5dcf5d",
                commandResolver: { _ in "/usr/local/bin/claude" },
                processRunner: runner
            )
            XCTFail("expected LifecycleError.nonZeroExit")
        } catch BackgroundAgentLifecycle.LifecycleError.nonZeroExit(let action, let code, let stderr, _) {
            XCTAssertEqual(action, .stop)
            XCTAssertEqual(code, 2)
            XCTAssertEqual(stderr, "Background agents are disabled by managed setting")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Health-Check classification

    func testHealthCheckAliveWhenExitZero() {
        XCTAssertEqual(
            BackgroundAgentLifecycle.classifyHealthCheck(exitCode: 0, stderr: ""),
            .alive
        )
    }

    func testHealthCheckUnknownOnDocumentedNoSuchSessionMarker() {
        XCTAssertEqual(
            BackgroundAgentLifecycle.classifyHealthCheck(
                exitCode: 1,
                stderr: "Error: no such session: 7c5dcf5d"
            ),
            .unknown
        )
    }

    func testHealthCheckUnknownOnUppercaseAndPunctuation() {
        XCTAssertEqual(
            BackgroundAgentLifecycle.classifyHealthCheck(
                exitCode: 1,
                stderr: "claude: NOT FOUND."
            ),
            .unknown
        )
    }

    func testHealthCheckErrorForUnclassifiedFailure() {
        if case .error(let reason) = BackgroundAgentLifecycle.classifyHealthCheck(
            exitCode: 127,
            stderr: "supervisor offline"
        ) {
            XCTAssertEqual(reason, "supervisor offline")
        } else {
            XCTFail("expected .error")
        }
    }

    func testHealthCheckErrorWithoutStderrIncludesExitCode() {
        if case .error(let reason) = BackgroundAgentLifecycle.classifyHealthCheck(
            exitCode: 3,
            stderr: ""
        ) {
            XCTAssertTrue(reason.contains("3"), "expected reason to mention exit code, got '\(reason)'")
        } else {
            XCTFail("expected .error")
        }
    }

    // MARK: - Health-Check end-to-end

    func testHealthCheckIntegratesWithProcessRunner() async {
        let runner = SpyProcessRunner(result: ProcessRunResult(
            exitCode: 1,
            stdout: "",
            stderr: "no such session"
        ))
        let result = await BackgroundAgentLifecycle.healthCheck(
            shortID: "deadbeef",
            commandResolver: { _ in "/usr/local/bin/claude" },
            processRunner: runner
        )
        XCTAssertEqual(result, .unknown)
        XCTAssertEqual(runner.recordedArguments, ["logs", "deadbeef"])
    }

    func testHealthCheckReturnsUnknownForEmptyShortID() async {
        let runner = SpyProcessRunner(result: ProcessRunResult(exitCode: 0, stdout: "", stderr: ""))
        let result = await BackgroundAgentLifecycle.healthCheck(
            shortID: "",
            commandResolver: { _ in "/usr/local/bin/claude" },
            processRunner: runner
        )
        XCTAssertEqual(result, .unknown)
        // Runner darf gar nicht erst angefasst werden.
        XCTAssertEqual(runner.callCount, 0)
    }
}

// MARK: - Spy

private final class SpyProcessRunner: ProcessRunner, @unchecked Sendable {
    let result: ProcessRunResult
    private(set) var recordedExecutable: String = ""
    private(set) var recordedArguments: [String] = []
    private(set) var recordedWorkingDirectory: String = ""
    private(set) var callCount = 0

    init(result: ProcessRunResult) {
        self.result = result
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: String,
        timeout: TimeInterval
    ) async throws -> ProcessRunResult {
        callCount += 1
        recordedExecutable = executable
        recordedArguments = arguments
        recordedWorkingDirectory = workingDirectory
        return result
    }
}
