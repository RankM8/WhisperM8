import XCTest
@testable import WhisperM8

/// E5/D5: CLI-Installation per Homebrew-Cask, nie doppelt, ohne echte Installation in Tests.
final class AgentCLIInstallerTests: XCTestCase {
    final class FakeRunner: AgentCLIProcessRunning, @unchecked Sendable {
        var result = CLIInstallRunResult(exitCode: 0, output: "", timedOut: false)
        private(set) var calls: [(executable: String, arguments: [String], environment: [String: String])] = []
        var onRun: (() -> Void)?

        func run(
            executable: String,
            arguments: [String],
            environment: [String: String],
            timeout: TimeInterval,
            onOutput: @escaping @Sendable (String) -> Void
        ) async -> CLIInstallRunResult {
            calls.append((executable, arguments, environment))
            onRun?()
            return result
        }
    }

    private func installer(
        runner: FakeRunner,
        claudePath: @escaping () -> String?,
        brew: String? = "/opt/homebrew/bin/brew"
    ) -> AgentCLIInstaller {
        AgentCLIInstaller(
            resolver: AgentCLIResolver(
                commandResolver: { $0 == "claude" ? claudePath() : nil },
                brewResolver: { brew }
            ),
            runner: runner,
            environment: { ["PATH": "/usr/bin"] },
            timeout: 5
        )
    }

    func testStateDistinguishesInstalledBrewAndNoBrew() {
        let present = AgentCLIResolver(commandResolver: { _ in "/Users/x/.local/bin/claude" }, brewResolver: { nil })
        XCTAssertEqual(present.state(of: .claude), .installed(path: "/Users/x/.local/bin/claude"))

        let canInstall = AgentCLIResolver(commandResolver: { _ in nil }, brewResolver: { "/opt/homebrew/bin/brew" })
        XCTAssertEqual(canInstall.state(of: .codex), .missingCanInstall(brewPath: "/opt/homebrew/bin/brew"))

        let none = AgentCLIResolver(commandResolver: { _ in nil }, brewResolver: { nil })
        XCTAssertEqual(none.state(of: .claude), .missingNoHomebrew)
    }

    func testExistingInstallationIsNeverInstalledTwice() async {
        let runner = FakeRunner()
        let result = await installer(runner: runner, claudePath: { "/Users/x/.local/bin/claude" })
            .install(.claude)
        XCTAssertEqual(result, .alreadyInstalled(path: "/Users/x/.local/bin/claude"))
        XCTAssertTrue(runner.calls.isEmpty, "bei vorhandener Installation darf kein brew laufen")
    }

    func testMissingHomebrewReportsHintWithoutRunning() async {
        let runner = FakeRunner()
        let result = await installer(runner: runner, claudePath: { nil }, brew: nil).install(.claude)
        XCTAssertEqual(result, .homebrewMissing)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testInstallRunsBrewCaskAndVerifiesCommandAfterwards() async {
        let runner = FakeRunner()
        var installed = false
        runner.onRun = { installed = true }
        let result = await installer(runner: runner, claudePath: { installed ? "/opt/homebrew/bin/claude" : nil })
            .install(.claude)

        XCTAssertEqual(result, .installed(path: "/opt/homebrew/bin/claude"))
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls[0].executable, "/opt/homebrew/bin/brew")
        XCTAssertEqual(runner.calls[0].arguments, ["install", "--cask", "claude-code"])
        XCTAssertEqual(runner.calls[0].environment["NONINTERACTIVE"], "1")
        XCTAssertEqual(AgentCLI.codex.brewCask, "codex")
    }

    func testNonZeroExitSurfacesTailOfOutput() async {
        let runner = FakeRunner()
        runner.result = CLIInstallRunResult(exitCode: 1, output: "a\nb\nError: cask not found", timedOut: false)
        let result = await installer(runner: runner, claudePath: { nil }).install(.claude)
        guard case .failed(let message) = result else { return XCTFail("erwartet failed, bekam \(result)") }
        XCTAssertTrue(message.contains("Error: cask not found"))
    }

    func testSuccessWithoutResolvableBinaryIsReportedAsFailure() async {
        let runner = FakeRunner()
        let result = await installer(runner: runner, claudePath: { nil }).install(.claude)
        guard case .failed = result else { return XCTFail("exit 0 ohne auffindbares Binary ist kein Erfolg") }
    }

    func testTimeoutIsReported() async {
        let runner = FakeRunner()
        runner.result = CLIInstallRunResult(exitCode: 15, output: "", timedOut: true)
        let result = await installer(runner: runner, claudePath: { nil }).install(.claude)
        XCTAssertEqual(result, .timedOut)
    }

    // MARK: LR-AU-022 · Chatstart ohne CLI legt keine Session an

    func testChatStartGateReportsMissingCLIPerProvider() {
        XCTAssertEqual(AgentChatStartGate.missingCLI(provider: .claude, kind: nil, commandResolver: { _ in nil }), .claude)
        XCTAssertEqual(AgentChatStartGate.missingCLI(provider: .codex, kind: .chat, commandResolver: { _ in nil }), .codex)
        XCTAssertEqual(AgentChatStartGate.missingCLI(provider: .claude, kind: .agentView, commandResolver: { _ in nil }), .claude)
    }

    func testChatStartGateLetsTerminalsAndInstalledCLIsThrough() {
        XCTAssertNil(AgentChatStartGate.missingCLI(provider: .claude, kind: .terminal, commandResolver: { _ in nil }))
        XCTAssertNil(AgentChatStartGate.missingCLI(provider: .claude, kind: nil, commandResolver: { _ in "/x/claude" }))
    }

    func testCommandNotFoundNameMapsToCLI() {
        XCTAssertEqual(AgentChatStartGate.cli(forCommandName: "Claude"), .claude)
        XCTAssertEqual(AgentChatStartGate.cli(forCommandName: "Codex"), .codex)
    }

    // MARK: LR-AU-022/DIK-015/ONB-003 · Versionsmanager-Orte (D5 „nie doppelt“)

    func testExtraDirectoriesCoverVersionManagersAndNewestNvmFirst() {
        let home = "/Users/x"
        let dirs = AgentCLISearchPaths.extraDirectories(home: home, listing: { base in
            base.hasSuffix(".nvm/versions/node") ? ["v18.19.0", "v20.11.1", "v9.0.0", ".DS_Store"] : []
        })
        for expected in ["/Users/x/.volta/bin", "/Users/x/.bun/bin", "/Users/x/.npm-global/bin",
                         "/Users/x/.local/share/mise/shims", "/Users/x/.asdf/shims"] {
            XCTAssertTrue(dirs.contains(expected), expected)
        }
        let nvm = dirs.filter { $0.contains(".nvm/") }
        XCTAssertEqual(nvm, ["/Users/x/.nvm/versions/node/v20.11.1/bin",
                             "/Users/x/.nvm/versions/node/v18.19.0/bin",
                             "/Users/x/.nvm/versions/node/v9.0.0/bin"], "numerisch sortiert, neueste zuerst")
    }

    func testFirstExecutableFindsCLIInVoltaDirectory() {
        let dirs = AgentCLISearchPaths.extraDirectories(home: "/Users/x", listing: { _ in [] })
        let found = AgentCLISearchPaths.firstExecutable("claude", in: dirs, isExecutable: { $0 == "/Users/x/.volta/bin/claude" })
        XCTAssertEqual(found, "/Users/x/.volta/bin/claude")
        XCTAssertNil(AgentCLISearchPaths.firstExecutable("claude", in: dirs, isExecutable: { _ in false }))
    }

    @MainActor
    func testCheckAgainInvalidatesLoginShellCacheButInitialCheckDoesNot() async {
        var invalidations = 0
        let model = AgentCLIInstallModel(
            cli: .claude,
            resolver: AgentCLIResolver(commandResolver: { _ in nil }, brewResolver: { nil }),
            invalidateEnvironment: { invalidations += 1 }
        )
        await model.recheck()
        XCTAssertEqual(invalidations, 0)
        await model.recheck(refreshEnvironment: true)
        XCTAssertEqual(invalidations, 1)
    }
}
