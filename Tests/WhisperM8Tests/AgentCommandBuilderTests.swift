import Foundation
import XCTest
@testable import WhisperM8

final class AgentCommandBuilderTests: XCTestCase {
    func testAgentCommandBuilderBuildsCodexNewAndResumeCommands() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.extraArgumentsResolver = { _ in [] }
        builder.codexServiceTierResolver = { .fast }
        let newSession = AgentChatSession(
            provider: .codex,
            projectID: project.id,
            title: "New",
            model: "gpt-5.5",
            reasoningEffort: "medium",
            initialPrompt: "Do the thing",
            imagePaths: ["/tmp/shot.png"]
        )

        let newCommand = try builder.command(for: newSession, project: project)

        XCTAssertEqual(newCommand.executablePath, "/usr/local/bin/codex")
        XCTAssertEqual(newCommand.workingDirectory, project.path)
        XCTAssertTrue(newCommand.arguments.contains("-C"))
        XCTAssertTrue(newCommand.arguments.contains(project.path))
        XCTAssertTrue(newCommand.arguments.contains("features.fast_mode=true"))
        XCTAssertTrue(newCommand.arguments.contains("service_tier=fast"))
        XCTAssertTrue(newCommand.arguments.contains("--image"))
        XCTAssertTrue(newCommand.arguments.contains("/tmp/shot.png"))
        XCTAssertEqual(newCommand.arguments.last, "Do the thing")

        let resumeSession = AgentChatSession(
            provider: .codex,
            projectID: project.id,
            externalSessionID: "abc",
            title: "Resume",
            hasLaunchedInitialPrompt: true
        )
        let resumeCommand = try builder.command(for: resumeSession, project: project)

        XCTAssertEqual(resumeCommand.arguments.first, "resume")
        XCTAssertTrue(resumeCommand.arguments.contains("features.fast_mode=true"))
        XCTAssertTrue(resumeCommand.arguments.contains("service_tier=fast"))
        XCTAssertTrue(resumeCommand.arguments.contains("abc"))
    }

    func testAgentCommandBuilderBuildsClaudeCommands() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.extraArgumentsResolver = { _ in [] }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "claude-session",
            title: "Claude",
            hasLaunchedInitialPrompt: true
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.executablePath, "/usr/local/bin/claude")
        XCTAssertEqual(command.arguments, ["--resume", "claude-session"])
        XCTAssertEqual(command.workingDirectory, project.path)
    }

    func testAgentCommandBuilderBuildsClaudeNewSessionWithStableSessionID() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.extraArgumentsResolver = { _ in [] }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "4D8F1E1D-7B4B-4F0B-9B6E-1552E2E827AA",
            title: "Claude"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.executablePath, "/usr/local/bin/claude")
        XCTAssertEqual(command.arguments, ["--session-id", "4D8F1E1D-7B4B-4F0B-9B6E-1552E2E827AA"])
        XCTAssertEqual(command.workingDirectory, project.path)
    }

    func testAgentCommandBuilderForksFromSourceWhenForkIDSetAndExternalIDUnbound() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.extraArgumentsResolver = { _ in [] }
        // Frischer Fork: eigene ID noch nicht gebunden, Quelle gesetzt.
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: nil,
            title: "Chat (Fork)",
            hasLaunchedInitialPrompt: false,
            forkSourceSessionID: "SOURCE-1111"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.arguments, ["--resume", "SOURCE-1111", "--fork-session"])
    }

    func testAgentCommandBuilderResumesOwnIDAfterForkBoundAndDoesNotReFork() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.extraArgumentsResolver = { _ in [] }
        // Nach dem Launch hat der SessionStart-Hook die neue Fork-ID gebunden.
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "FORK-2222",
            title: "Chat (Fork)",
            hasLaunchedInitialPrompt: true,
            forkSourceSessionID: "SOURCE-1111"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.arguments, ["--resume", "FORK-2222"])
        XCTAssertFalse(command.arguments.contains("--fork-session"), "Restart darf nicht erneut forken")
    }

    func testAgentCommandBuilderProducesAgentsSubcommandForAgentViewSession() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.extraArgumentsResolver = { _ in [] }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: nil,
            title: "Agent View",
            kind: .agentView
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.executablePath, "/usr/local/bin/claude")
        // Erstes Argument muss `agents` sein — Claude's dashboard
        // subcommand. KEIN --resume / --session-id / --settings.
        XCTAssertEqual(command.arguments.first, "agents")
        XCTAssertFalse(command.arguments.contains("--resume"))
        XCTAssertFalse(command.arguments.contains("--session-id"))
        XCTAssertFalse(command.arguments.contains("--settings"))
    }

    // MARK: - Background-Agent (Phase 1)

    func testAgentCommandBuilderProducesAttachCommandForBackgroundChat() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.extraArgumentsResolver = { _ in [] }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "BG",
            kind: .backgroundChat,
            backgroundShortID: "7c5dcf5d"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.executablePath, "/usr/local/bin/claude")
        // claude attach <shortID> — keine --bg/--agent/--resume.
        XCTAssertEqual(command.arguments, ["attach", "7c5dcf5d"])
        XCTAssertFalse(command.arguments.contains("--bg"))
        XCTAssertFalse(command.arguments.contains("--resume"))
        XCTAssertFalse(command.arguments.contains("--session-id"))
        XCTAssertEqual(command.keyboardProfile, .claudeCodeChat)
    }

    func testAgentCommandBuilderRefusesAttachForBackgroundChatWithoutShortID() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.extraArgumentsResolver = { _ in [] }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Pending BG",
            kind: .backgroundChat,
            backgroundShortID: nil
        )

        XCTAssertThrowsError(try builder.command(for: session, project: project)) { error in
            guard let cmdErr = error as? AgentCommandError else {
                return XCTFail("expected AgentCommandError, got \(error)")
            }
            if case .missingBackgroundShortID = cmdErr {
                // ok
            } else {
                XCTFail("expected missingBackgroundShortID, got \(cmdErr)")
            }
        }
    }

    func testBackgroundSpawnArgumentsBuildsMinimalArgs() {
        let args = AgentCommandBuilder.backgroundSpawnArguments(
            initialPrompt: "investigate flaky test"
        )
        XCTAssertEqual(args, ["--bg", "investigate flaky test"])
    }

    func testBackgroundSpawnArgumentsIncludesAgentAndPermissionMode() {
        let args = AgentCommandBuilder.backgroundSpawnArguments(
            initialPrompt: "review pr",
            subAgent: "code-reviewer",
            permissionMode: "acceptEdits"
        )
        XCTAssertEqual(args, [
            "--bg",
            "--agent", "code-reviewer",
            "--permission-mode", "acceptEdits",
            "review pr"
        ])
    }

    func testBackgroundSpawnArgumentsPrependsExtraArgumentsBeforePrompt() {
        let args = AgentCommandBuilder.backgroundSpawnArguments(
            initialPrompt: "do stuff",
            extraArguments: ["--verbose", "--effort", "high"]
        )
        XCTAssertEqual(args, ["--bg", "--verbose", "--effort", "high", "do stuff"])
    }

    func testBackgroundSpawnArgumentsTrimsAndIgnoresEmptyAgentAndMode() {
        let args = AgentCommandBuilder.backgroundSpawnArguments(
            initialPrompt: "x",
            subAgent: "   ",
            permissionMode: ""
        )
        XCTAssertEqual(args, ["--bg", "x"])
    }

    func testBackgroundSpawnArgumentsPrependsSettingsBeforeBg() {
        // --settings muss VOR --bg stehen, sonst liest Claude die Hook-
        // Konfiguration nicht ein bevor die Background-Session aufgesetzt
        // wird.
        let args = AgentCommandBuilder.backgroundSpawnArguments(
            initialPrompt: "x",
            settingsFilePath: "/tmp/hooks.json"
        )
        XCTAssertEqual(args, ["--settings", "/tmp/hooks.json", "--bg", "x"])
    }

    func testBackgroundSpawnArgumentsIgnoresWhitespaceOnlySettingsPath() {
        // Defensiv: leerer Pfad darf NICHT als `--settings ""` rausgehen,
        // sonst wuerde Claude einen Parser-Error werfen.
        let args = AgentCommandBuilder.backgroundSpawnArguments(
            initialPrompt: "x",
            settingsFilePath: "   "
        )
        XCTAssertEqual(args, ["--bg", "x"])
    }

    func testBackgroundSpawnArgumentsCombinesSettingsAgentAndExtras() {
        let args = AgentCommandBuilder.backgroundSpawnArguments(
            initialPrompt: "review",
            settingsFilePath: "/tmp/hooks.json",
            subAgent: "code-reviewer",
            permissionMode: "acceptEdits",
            extraArguments: ["--verbose"]
        )
        XCTAssertEqual(args, [
            "--settings", "/tmp/hooks.json",
            "--bg",
            "--agent", "code-reviewer",
            "--permission-mode", "acceptEdits",
            "--verbose",
            "review"
        ])
    }

    func testAgentCommandBuilderDoesNotSilentlyCreateNewSessionWhenResumeIDIsMissing() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.extraArgumentsResolver = { _ in [] }
        let launchedSession = AgentChatSession(
            provider: .codex,
            projectID: project.id,
            title: "Running Task",
            hasLaunchedInitialPrompt: true
        )

        XCTAssertThrowsError(try builder.command(for: launchedSession, project: project)) { error in
            XCTAssertEqual(error as? AgentCommandError, .missingExternalSessionID("Running Task"))
        }
    }

    func testParseArgumentsHandlesWhitespaceAndQuotes() {
        XCTAssertEqual(AgentCommandBuilder.parseArguments(""), [])
        XCTAssertEqual(AgentCommandBuilder.parseArguments("   "), [])
        XCTAssertEqual(AgentCommandBuilder.parseArguments("--dangerously-skip-permissions"), ["--dangerously-skip-permissions"])
        XCTAssertEqual(
            AgentCommandBuilder.parseArguments("--ask-for-approval untrusted"),
            ["--ask-for-approval", "untrusted"]
        )
        XCTAssertEqual(
            AgentCommandBuilder.parseArguments("--text \"hello world\" --flag"),
            ["--text", "hello world", "--flag"]
        )
        // Quotes ohne Whitespace dazwischen werden konkateniert — POSIX-kompatibel.
        XCTAssertEqual(
            AgentCommandBuilder.parseArguments("--text 'mit ''doppelt'' tokens'"),
            ["--text", "mit doppelt tokens"]
        )
    }

    func testAgentCommandBuilderPrependsClaudeExtraArgumentsForResume() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.extraArgumentsResolver = { provider in
            provider == .claude ? ["--dangerously-skip-permissions"] : []
        }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "claude-session",
            title: "Claude",
            hasLaunchedInitialPrompt: true
        )

        let command = try builder.command(for: session, project: project)

        // Extra-Args MÜSSEN vor `--resume` stehen, sonst würden sie als Sub-Command-Args behandelt.
        XCTAssertEqual(command.arguments, ["--dangerously-skip-permissions", "--resume", "claude-session"])
    }

    func testAgentCommandBuilderPrependsCodexExtraArgumentsForNewAndResume() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.extraArgumentsResolver = { provider in
            provider == .codex ? ["--ask-for-approval", "untrusted"] : []
        }
        builder.codexServiceTierResolver = { .fast }

        let newSession = AgentChatSession(
            provider: .codex,
            projectID: project.id,
            title: "New",
            model: "gpt-5.5",
            reasoningEffort: "medium",
            initialPrompt: "Do it"
        )
        let newCommand = try builder.command(for: newSession, project: project)
        XCTAssertEqual(Array(newCommand.arguments.prefix(2)), ["--ask-for-approval", "untrusted"])
        XCTAssertTrue(newCommand.arguments.contains("-C"))
        XCTAssertEqual(newCommand.arguments.last, "Do it")

        let resumeSession = AgentChatSession(
            provider: .codex,
            projectID: project.id,
            externalSessionID: "abc",
            title: "Resume",
            hasLaunchedInitialPrompt: true
        )
        let resumeCommand = try builder.command(for: resumeSession, project: project)
        // `resume` Sub-Command muss als erstes stehen; Extras kommen direkt danach.
        XCTAssertEqual(Array(resumeCommand.arguments.prefix(3)), ["resume", "--ask-for-approval", "untrusted"])
        XCTAssertEqual(resumeCommand.arguments.last, "abc")
    }

    func testAgentCommandBuilderCanForceStandardCodexServiceTier() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.extraArgumentsResolver = { _ in [] }
        builder.codexServiceTierResolver = { .standard }
        let session = AgentChatSession(
            provider: .codex,
            projectID: project.id,
            title: "New",
            model: "gpt-5.5",
            reasoningEffort: "medium"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertTrue(command.arguments.contains("service_tier=default"))
        XCTAssertFalse(command.arguments.contains("service_tier=fast"))
    }
}
