import Foundation
import XCTest
@testable import WhisperM8

final class BackgroundAgentSpawnerTests: XCTestCase {

    // MARK: - parseShortID

    func testParseShortIDFromCyanColoredOutput() {
        // Genau das Format das Claude 2.1.139 wirklich druckt, auch wenn
        // stdout an eine Pipe geht: die Short-ID ist in cyan (\x1b[36m...\x1b[39m)
        // eingewickelt, und die Erklaerungszeilen sind dim (\x1b[2m...\x1b[22m).
        let stdout = "backgrounded · \u{1B}[36m07535129\u{1B}[39m\n" +
                     "\u{1B}[2m  claude agents             list sessions\u{1B}[22m\n" +
                     "\u{1B}[2m  claude attach 07535129    open in this terminal\u{1B}[22m\n"
        XCTAssertEqual(BackgroundAgentSpawner.parseShortID(from: stdout), "07535129")
    }

    func testStripAnsiEscapesRemovesCsiSequences() {
        let raw = "backgrounded · \u{1B}[36m7c5dcf5d\u{1B}[39m\n  \u{1B}[2mhint\u{1B}[22m"
        let stripped = BackgroundAgentSpawner.stripAnsiEscapes(raw)
        XCTAssertEqual(stripped, "backgrounded · 7c5dcf5d\n  hint")
    }

    func testStripAnsiEscapesIsNoopForPlainText() {
        let raw = "no ansi here, just plain · text 1234"
        XCTAssertEqual(BackgroundAgentSpawner.stripAnsiEscapes(raw), raw)
    }

    func testParseShortIDFromCanonicalOutput() {
        // Standard-Output von `claude --bg` aus der offiziellen Doku.
        let stdout = """
        backgrounded · 7c5dcf5d
          claude agents             list sessions
          claude attach 7c5dcf5d    open in this terminal
          claude logs 7c5dcf5d      show recent output
          claude stop 7c5dcf5d      stop this session
        """
        XCTAssertEqual(BackgroundAgentSpawner.parseShortID(from: stdout), "7c5dcf5d")
    }

    func testParseShortIDAcceptsAsciiDashSeparator() {
        // Fallback fuer Terminals ohne UTF-8-Middle-Dot.
        let stdout = "backgrounded - abcd1234\n"
        XCTAssertEqual(BackgroundAgentSpawner.parseShortID(from: stdout), "abcd1234")
    }

    func testParseShortIDAcceptsColonSeparator() {
        let stdout = "backgrounded: deadbeef\n"
        XCTAssertEqual(BackgroundAgentSpawner.parseShortID(from: stdout), "deadbeef")
    }

    func testParseShortIDIgnoresLeadingWhitespaceAndCase() {
        let stdout = "   Backgrounded · 1a2b3c4d  \n"
        XCTAssertEqual(BackgroundAgentSpawner.parseShortID(from: stdout), "1a2b3c4d")
    }

    func testParseShortIDFindsLineEvenWhenSurroundedByOtherOutput() {
        let stdout = """
        spinning up supervisor…
        warming caches
        backgrounded · cafebabe
        registered with daemon
        """
        XCTAssertEqual(BackgroundAgentSpawner.parseShortID(from: stdout), "cafebabe")
    }

    func testParseShortIDReturnsNilWhenLineMissing() {
        let stdout = "claude: command not found\n"
        XCTAssertNil(BackgroundAgentSpawner.parseShortID(from: stdout))
    }

    func testParseShortIDReturnsNilWhenTokenIsNotHex() {
        // Output sieht aehnlich aus, aber das Token enthaelt nicht-Hex-Zeichen.
        let stdout = "backgrounded · zzzzzzzz\n"
        XCTAssertNil(BackgroundAgentSpawner.parseShortID(from: stdout))
    }

    func testParseShortIDReturnsNilForShortToken() {
        // <6 Zeichen — wir verlangen min. 6 Hex-Zeichen.
        let stdout = "backgrounded · abc\n"
        XCTAssertNil(BackgroundAgentSpawner.parseShortID(from: stdout))
    }

    func testIsLikelyShortIDAcceptsTypicalHashLengths() {
        XCTAssertTrue(BackgroundAgentSpawner.isLikelyShortID("7c5dcf5d"))     // 8
        XCTAssertTrue(BackgroundAgentSpawner.isLikelyShortID("abcdef"))       // 6
        XCTAssertTrue(BackgroundAgentSpawner.isLikelyShortID("1234567890abcd")) // 14
    }

    func testIsLikelyShortIDRejectsNonHexAndWrongLength() {
        XCTAssertFalse(BackgroundAgentSpawner.isLikelyShortID(""))
        XCTAssertFalse(BackgroundAgentSpawner.isLikelyShortID("abcde"))             // 5 < 6
        XCTAssertFalse(BackgroundAgentSpawner.isLikelyShortID("12345678901234567")) // 17 > 16
        XCTAssertFalse(BackgroundAgentSpawner.isLikelyShortID("XYZ12345"))          // uppercase non-hex
        XCTAssertFalse(BackgroundAgentSpawner.isLikelyShortID("abcd 123"))          // contains space
        XCTAssertFalse(BackgroundAgentSpawner.isLikelyShortID("ABCDEF12"))          // wir akzeptieren nur lowercase
    }

    // MARK: - spawn (mit Mock-Runner)

    /// Erfolgs-Pfad: ProcessRunner liefert exit 0 + gueltigen stdout → SpawnResult.
    func testSpawnReturnsResultOnSuccess() async throws {
        let runner = MockProcessRunner(result: ProcessRunResult(
            exitCode: 0,
            stdout: "backgrounded · 7c5dcf5d\n  claude attach 7c5dcf5d\n",
            stderr: ""
        ))
        let projectPath = FileManager.default.temporaryDirectory.path
        let result = try await BackgroundAgentSpawner.spawn(
            initialPrompt: "hello",
            projectPath: projectPath,
            commandResolver: { command in "/usr/local/bin/\(command)" },
            processRunner: runner
        )
        XCTAssertEqual(result.shortID, "7c5dcf5d")
        XCTAssertEqual(runner.recordedArguments, ["--bg", "hello"])
        XCTAssertEqual(runner.recordedWorkingDirectory, projectPath)
        XCTAssertEqual(runner.recordedExecutable, "/usr/local/bin/claude")
    }

    func testSpawnPassesEnvironmentOverridesToRunnerUnchanged() async throws {
        let runner = MockProcessRunner(result: ProcessRunResult(
            exitCode: 0,
            stdout: "backgrounded · cafebabe\n",
            stderr: ""
        ))
        let environmentOverrides = [
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:19001",
            "CLAUDE_CODE_ALWAYS_ENABLE_EFFORT": "1",
        ]

        _ = try await BackgroundAgentSpawner.spawn(
            initialPrompt: "route this",
            projectPath: FileManager.default.temporaryDirectory.path,
            environmentOverrides: environmentOverrides,
            commandResolver: { _ in "/usr/local/bin/claude" },
            processRunner: runner
        )

        XCTAssertEqual(runner.recordedEnvironmentOverrides, environmentOverrides)
    }

    func testSpawnPassesSettingsBeforeBackgroundFlagToRunner() async throws {
        let runner = MockProcessRunner(result: ProcessRunResult(
            exitCode: 0,
            stdout: "backgrounded · cafebabe\n",
            stderr: ""
        ))

        _ = try await BackgroundAgentSpawner.spawn(
            initialPrompt: "worker",
            projectPath: FileManager.default.temporaryDirectory.path,
            settingsFilePath: "/app-support/session-worker.json",
            environmentOverrides: ["ANTHROPIC_BASE_URL": "http://127.0.0.1:19002"],
            commandResolver: { _ in "/usr/local/bin/claude" },
            processRunner: runner
        )

        XCTAssertEqual(runner.recordedArguments, [
            "--settings", "/app-support/session-worker.json", "--bg", "worker",
        ])
    }

    func testSpawnPassesSubAgentAndPermissionMode() async throws {
        let runner = MockProcessRunner(result: ProcessRunResult(
            exitCode: 0,
            stdout: "backgrounded · cafebabe\n",
            stderr: ""
        ))
        _ = try await BackgroundAgentSpawner.spawn(
            initialPrompt: "review",
            projectPath: FileManager.default.temporaryDirectory.path,
            subAgent: "code-reviewer",
            permissionMode: "acceptEdits",
            commandResolver: { _ in "/usr/local/bin/claude" },
            processRunner: runner
        )
        XCTAssertEqual(runner.recordedArguments, [
            "--bg",
            "--agent", "code-reviewer",
            "--permission-mode", "acceptEdits",
            "review"
        ])
    }

    func testSpawnThrowsWhenClaudeNotFound() async {
        let runner = MockProcessRunner(result: ProcessRunResult(exitCode: 0, stdout: "", stderr: ""))
        do {
            _ = try await BackgroundAgentSpawner.spawn(
                initialPrompt: "x",
                projectPath: FileManager.default.temporaryDirectory.path,
                commandResolver: { _ in nil },
                processRunner: runner
            )
            XCTFail("expected SpawnError.claudeNotFound")
        } catch BackgroundAgentSpawner.SpawnError.claudeNotFound {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSpawnThrowsWhenProjectMissing() async {
        let runner = MockProcessRunner(result: ProcessRunResult(exitCode: 0, stdout: "", stderr: ""))
        do {
            _ = try await BackgroundAgentSpawner.spawn(
                initialPrompt: "x",
                projectPath: "/this/does/not/exist/nope",
                commandResolver: { _ in "/usr/local/bin/claude" },
                processRunner: runner
            )
            XCTFail("expected SpawnError.projectMissing")
        } catch BackgroundAgentSpawner.SpawnError.projectMissing(let path) {
            XCTAssertEqual(path, "/this/does/not/exist/nope")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSpawnThrowsNonZeroExitWithStderr() async {
        let runner = MockProcessRunner(result: ProcessRunResult(
            exitCode: 2,
            stdout: "",
            stderr: "Background agents are disabled by managed setting"
        ))
        do {
            _ = try await BackgroundAgentSpawner.spawn(
                initialPrompt: "x",
                projectPath: FileManager.default.temporaryDirectory.path,
                commandResolver: { _ in "/usr/local/bin/claude" },
                processRunner: runner
            )
            XCTFail("expected SpawnError.nonZeroExit")
        } catch BackgroundAgentSpawner.SpawnError.nonZeroExit(let code, let stderr) {
            XCTAssertEqual(code, 2)
            XCTAssertEqual(stderr, "Background agents are disabled by managed setting")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSpawnThrowsShortIDNotFoundWhenOutputIsUnparseable() async {
        let runner = MockProcessRunner(result: ProcessRunResult(
            exitCode: 0,
            stdout: "claude: unknown flag --bg\n",
            stderr: ""
        ))
        do {
            _ = try await BackgroundAgentSpawner.spawn(
                initialPrompt: "x",
                projectPath: FileManager.default.temporaryDirectory.path,
                commandResolver: { _ in "/usr/local/bin/claude" },
                processRunner: runner
            )
            XCTFail("expected SpawnError.shortIDNotFound")
        } catch BackgroundAgentSpawner.SpawnError.shortIDNotFound(let stdout) {
            XCTAssertEqual(stdout, "claude: unknown flag --bg\n")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

// MARK: - Mock

private final class MockProcessRunner: ProcessRunner, @unchecked Sendable {
    let result: ProcessRunResult
    private(set) var recordedExecutable: String = ""
    private(set) var recordedArguments: [String] = []
    private(set) var recordedWorkingDirectory: String = ""
    private(set) var recordedEnvironmentOverrides: [String: String] = [:]

    init(result: ProcessRunResult) {
        self.result = result
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: String,
        environmentOverrides: [String: String],
        timeout: TimeInterval
    ) async throws -> ProcessRunResult {
        self.recordedExecutable = executable
        self.recordedArguments = arguments
        self.recordedWorkingDirectory = workingDirectory
        self.recordedEnvironmentOverrides = environmentOverrides
        return result
    }
}
