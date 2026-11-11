import XCTest
@testable import WhisperM8

/// `claude attach` nimmt nur `<id|name>` an (CLI 2.1.322). Startoptionen des
/// Chats (`--dangerously-skip-permissions`, `--chrome`, `--settings` …) ließen
/// den Aufruf mit dem Usage-Text scheitern; der Tab hing dann tot neben einem
/// weiterlaufenden Hintergrund-Agent.
final class AgentCommandBuilderAttachTests: XCTestCase {
    private let userExtras = ["--dangerously-skip-permissions", "--chrome"]

    private func makeBuilder() -> AgentCommandBuilder {
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { false }
        let extras = userExtras
        builder.extraArgumentsResolver = { _ in extras }
        return builder
    }

    func testAttachArgumentsCarryOnlyTheShortID() {
        XCTAssertEqual(AgentCommandBuilder.attachArguments(shortID: "1f353dce"), ["attach", "1f353dce"])
    }

    func testResumeFallbackAttachIgnoresUserArgumentsAndHookSettings() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = makeBuilder()
        builder.extraLaunchArguments = ["--settings", "/tmp/hooks.json"]
        builder.backgroundWorkerShortIDResolver = { sessionID, _ in
            sessionID == "1f353dce-783f-407c-a2d4-402c5e884d59" ? "1f353dce" : nil
        }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "1f353dce-783f-407c-a2d4-402c5e884d59",
            title: "Läuft als Hintergrund-Agent",
            hasLaunchedInitialPrompt: true
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.arguments, ["attach", "1f353dce"])
        XCTAssertTrue(command.isBackgroundAttachFallback)
    }

    func testBackgroundChatAttachIgnoresUserArguments() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        let builder = makeBuilder()
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "BG",
            kind: .backgroundChat,
            backgroundShortID: "7c5dcf5d"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.arguments, ["attach", "7c5dcf5d"])
    }

    func testNormalResumeKeepsUserArgumentsWhenNoWorkerRuns() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = makeBuilder()
        builder.backgroundWorkerShortIDResolver = { _, _ in nil }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "claude-session",
            title: "Claude",
            hasLaunchedInitialPrompt: true
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.arguments, userExtras + ["--resume", "claude-session"])
        XCTAssertFalse(command.isBackgroundAttachFallback)
    }

    // MARK: - Rückweg nach gescheitertem Attach

    func testResumeFallbackStartNeverAttachesAgain() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = makeBuilder()
        var resolverCalled = false
        builder.backgroundWorkerShortIDResolver = { _, _ in
            resolverCalled = true
            return "1f353dce"
        }
        builder.backgroundAttachAllowed = false
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "1f353dce-783f-407c-a2d4-402c5e884d59",
            title: "Rückweg",
            hasLaunchedInitialPrompt: true
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.arguments, userExtras + ["--resume", "1f353dce-783f-407c-a2d4-402c5e884d59"])
        XCTAssertFalse(command.isBackgroundAttachFallback)
        XCTAssertFalse(resolverCalled, "Rückweg-Start fragt den Worker gar nicht erst ab")
    }

    // MARK: - Auslöser starten auch beendete Tabs

    func testTriggeredLaunchAllowedWithoutRunningProcess() {
        XCTAssertTrue(AgentCommandBuilder.allowsTriggeredLaunch(controllerIsRunning: nil), "kein Controller")
        XCTAssertTrue(AgentCommandBuilder.allowsTriggeredLaunch(controllerIsRunning: false), "beendeter Controller (toter Tab)")
        XCTAssertFalse(AgentCommandBuilder.allowsTriggeredLaunch(controllerIsRunning: true), "laufender Prozess bleibt")
    }
}
