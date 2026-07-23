import Foundation
import XCTest
@testable import WhisperM8

final class AgentCommandBuilderTests: XCTestCase {
    func testAgentCommandBuilderBuildsCodexNewAndResumeCommands() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { false }
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
        builder.gptFastModeEnabledResolver = { false }
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

    func testAgentCommandBuilderBuildsClaudeNewSessionFreshWithoutSessionID() throws {
        // Weg B (Superset-Prinzip): Neue Claude-Sessions starten OHNE
        // `--session-id`. Claude vergibt die ID selbst; SessionStart-Hook +
        // Indexer-Merge binden die reale ID nach. Eine vor dem ersten Launch
        // gesetzte externalSessionID wird NICHT mehr erzwungen.
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { false }
        builder.extraArgumentsResolver = { _ in [] }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "4D8F1E1D-7B4B-4F0B-9B6E-1552E2E827AA",
            title: "Claude"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.executablePath, "/usr/local/bin/claude")
        XCTAssertFalse(command.arguments.contains("--session-id"), "Weg B vergibt keine Vorab-ID")
        XCTAssertFalse(command.arguments.contains("--resume"), "nicht-gelaunchte Session resumed nicht")
        XCTAssertEqual(command.workingDirectory, project.path)
    }

    func testAgentCommandBuilderForksFromSourceWhenForkIDSetAndExternalIDUnbound() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { false }
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
        builder.gptFastModeEnabledResolver = { false }
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
        builder.gptFastModeEnabledResolver = { false }
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
        builder.gptFastModeEnabledResolver = { false }
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
        builder.gptFastModeEnabledResolver = { false }
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

    func testBackgroundSpawnArgumentsRemovesSeparateUserSettingsWhenInternalSettingsExist() {
        let args = AgentCommandBuilder.backgroundSpawnArguments(
            initialPrompt: "x",
            settingsFilePath: "/tmp/hooks.json",
            extraArguments: ["--verbose", "--settings", "/tmp/custom.json", "--effort", "high"]
        )
        XCTAssertEqual(args, [
            "--settings", "/tmp/hooks.json",
            "--bg", "--verbose", "--effort", "high", "x",
        ])
    }

    func testBackgroundSpawnArgumentsRemovesEqualsUserSettingsWhenInternalSettingsExist() {
        let args = AgentCommandBuilder.backgroundSpawnArguments(
            initialPrompt: "x",
            settingsFilePath: "/tmp/hooks.json",
            extraArguments: ["--settings=/tmp/custom.json", "--verbose"]
        )
        XCTAssertEqual(args, ["--settings", "/tmp/hooks.json", "--bg", "--verbose", "x"])
    }

    func testBackgroundSpawnArgumentsRemovesAllMixedUserSettingsWhenInternalSettingsExist() {
        let args = AgentCommandBuilder.backgroundSpawnArguments(
            initialPrompt: "x",
            settingsFilePath: "/tmp/hooks.json",
            extraArguments: [
                "--settings=first.json", "--verbose",
                "--settings", "second.json",
                "--effort", "high",
                "--settings=third.json",
                "--settings",
            ]
        )
        XCTAssertEqual(args, [
            "--settings", "/tmp/hooks.json",
            "--bg", "--verbose", "--effort", "high", "x",
        ])
    }

    func testBackgroundSpawnArgumentsRemovesTokenAfterDanglingUserSettingsFlag() {
        let args = AgentCommandBuilder.backgroundSpawnArguments(
            initialPrompt: "x",
            settingsFilePath: "/tmp/hooks.json",
            extraArguments: ["--verbose", "--settings", "--effort", "high"]
        )
        // Claude wertet `--effort` hier als Settings-Wert. Die Sanitization
        // bildet diese Parser-Semantik ab und entfernt deshalb beide Tokens.
        XCTAssertEqual(args, [
            "--settings", "/tmp/hooks.json",
            "--bg", "--verbose", "high", "x",
        ])
    }

    func testBackgroundSpawnArgumentsKeepsUserSettingsWithoutInternalSettings() {
        let extras = [
            "--settings", "custom.json",
            "--settings=other.json",
            "--settings",
        ]
        let args = AgentCommandBuilder.backgroundSpawnArguments(
            initialPrompt: "x",
            extraArguments: extras
        )
        XCTAssertEqual(args, ["--bg"] + extras + ["x"])
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
        builder.gptFastModeEnabledResolver = { false }
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
        builder.gptFastModeEnabledResolver = { false }
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
        builder.gptFastModeEnabledResolver = { false }
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
        builder.gptFastModeEnabledResolver = { false }
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

// MARK: - Claude-GPT-Backend

extension AgentCommandBuilderTests {
    func testGPTRouterCoreEnvironmentReturnsNilWhenBackendIsDisabled() {
        var builder = AgentCommandBuilder()
        builder.gptBackendEnabledResolver = { false }
        builder.gptFastModeEnabledResolver = { true }
        builder.gptRouterPortResolver = { 19_001 }
        builder.gptDefaultModelResolver = { "gpt-5.6-terra" }
        builder.gptSubagentModelResolver = { "gpt-5.6-luna" }

        XCTAssertNil(builder.gptRouterCoreEnvironment())
    }

    func testBackgroundDispatcherCoreEnvironmentUsesCanonicalPickerAndContextInvariants() {
        var builder = AgentCommandBuilder()
        builder.gptBackendEnabledResolver = { true }
        builder.gptPickerModelResolver = { "" }
        builder.gptFastModeEnabledResolver = { true }
        builder.gptRouterPortResolver = { 19_002 }
        builder.gptDefaultModelResolver = { "" }
        builder.gptSubagentModelResolver = { "" }

        XCTAssertEqual(builder.gptRouterCoreEnvironment(), [
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:19002",
            "ANTHROPIC_CUSTOM_MODEL_OPTION": "gpt-5.6-sol-fast",
            "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME": "gpt-5.6-sol-fast",
            "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION": "Priority-Tier (1,5× Speed, 2,5× Credits) — unterstützt: GPT-5.6 Sol/Terra/Luna, GPT-5.5 und GPT-5.4/Mini",
            "CLAUDE_CODE_ALWAYS_ENABLE_EFFORT": "1",
            "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "272000",
            "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "1000000",
            "WHISPERM8_GPT56_CONTEXT_WINDOW": "272000",
        ])
    }

    func testRouterCoreCanonicalizesKnownPickerAndRejectsUnknownConfiguredModels() {
        var builder = AgentCommandBuilder()
        builder.gptBackendEnabledResolver = { true }
        builder.gptFastModeEnabledResolver = { true }
        builder.gptPickerModelResolver = { "  GPT-5.4-MINI-FAST[1M]  " }
        builder.gptSubagentModelResolver = { "gpt-5.3-codex-spark" }
        builder.gptContextWindowResolver = { 272_000 }

        let environment = builder.gptRouterCoreEnvironment()

        XCTAssertEqual(environment?["ANTHROPIC_CUSTOM_MODEL_OPTION"], "gpt-5.4-mini")
        XCTAssertEqual(environment?["ANTHROPIC_CUSTOM_MODEL_OPTION_NAME"], "gpt-5.4-mini")
        XCTAssertEqual(
            environment?["ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION"],
            "Standard-Tier — unterstützt: GPT-5.6 Sol/Terra/Luna, GPT-5.5 und GPT-5.4/Mini"
        )
        XCTAssertEqual(environment?["CLAUDE_CODE_SUBAGENT_MODEL"], "gpt-5.6-sol-fast")
        XCTAssertEqual(environment?["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "272000")
        XCTAssertEqual(environment?["CLAUDE_CODE_AUTO_COMPACT_WINDOW"], "1000000")
    }

    func testExperimental372KProfileForcesSolAndKeepsNativeOneMillionCeiling() {
        var builder = AgentCommandBuilder()
        builder.gptBackendEnabledResolver = { true }
        builder.gptFastModeEnabledResolver = { false }
        builder.gptPickerModelResolver = { "gpt-5.6-terra" }
        builder.gptDefaultModelResolver = { "gpt-5.6-luna" }
        builder.gptSubagentModelResolver = { "gpt-5.6-terra-fast" }
        builder.gptContextWindowResolver = { 372_000 }

        let environment = builder.gptRouterCoreEnvironment()

        XCTAssertEqual(environment?["ANTHROPIC_CUSTOM_MODEL_OPTION"], "gpt-5.6-sol")
        XCTAssertEqual(environment?["CLAUDE_CODE_SUBAGENT_MODEL"], "gpt-5.6-sol")
        XCTAssertEqual(
            environment?["ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION"],
            "Standard-Tier — experimentelles 372k-Profil: nur GPT-5.6 Sol"
        )
        XCTAssertEqual(environment?["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "372000")
        XCTAssertEqual(environment?["CLAUDE_CODE_AUTO_COMPACT_WINDOW"], "1000000")
        XCTAssertEqual(environment?["WHISPERM8_GPT56_CONTEXT_WINDOW"], "372000")
    }

    func testOversizedContextValueFallsBackToStandardProfile() {
        var builder = AgentCommandBuilder()
        builder.gptBackendEnabledResolver = { true }
        builder.gptFastModeEnabledResolver = { false }
        builder.gptPickerModelResolver = { "gpt-5.6-sol" }
        builder.gptContextWindowResolver = { 500_000 }

        let environment = builder.gptRouterCoreEnvironment()

        XCTAssertEqual(environment?["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "272000")
        XCTAssertEqual(environment?["ANTHROPIC_CUSTOM_MODEL_OPTION"], "gpt-5.6-sol")
    }

    func testRouterCoreFallsBackToCanonicalPickerForUnknownID() {
        var builder = AgentCommandBuilder()
        builder.gptBackendEnabledResolver = { true }
        builder.gptFastModeEnabledResolver = { false }
        builder.gptPickerModelResolver = { "gpt-5.6-orbit" }

        XCTAssertEqual(
            builder.gptRouterCoreEnvironment()?["ANTHROPIC_CUSTOM_MODEL_OPTION"],
            "gpt-5.6-sol"
        )
    }

    func testGPTRouterCoreEnvironmentFastifiesExplicitPlainPickerModel() {
        var builder = AgentCommandBuilder()
        builder.gptBackendEnabledResolver = { true }
        builder.gptFastModeEnabledResolver = { true }
        builder.gptPickerModelResolver = { "  gpt-5.6-luna  " }
        builder.gptDefaultModelResolver = { "gpt-5.6-terra" }

        let environment = builder.gptRouterCoreEnvironment()

        XCTAssertEqual(environment?["ANTHROPIC_CUSTOM_MODEL_OPTION"], "gpt-5.6-luna-fast")
        XCTAssertEqual(environment?["ANTHROPIC_CUSTOM_MODEL_OPTION_NAME"], "gpt-5.6-luna-fast")
        XCTAssertEqual(
            environment?["ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION"],
            "Priority-Tier (1,5× Speed, 2,5× Credits) — unterstützt: GPT-5.6 Sol/Terra/Luna, GPT-5.5 und GPT-5.4/Mini"
        )
    }

    func testGPTRouterCoreEnvironmentKeepsExplicitFastPickerModelWhenToggleIsOff() {
        var builder = AgentCommandBuilder()
        builder.gptBackendEnabledResolver = { true }
        builder.gptFastModeEnabledResolver = { false }
        builder.gptPickerModelResolver = { "gpt-5.6-terra-fast" }
        builder.gptDefaultModelResolver = { "gpt-5.6-sol" }

        let environment = builder.gptRouterCoreEnvironment()

        XCTAssertEqual(environment?["ANTHROPIC_CUSTOM_MODEL_OPTION"], "gpt-5.6-terra-fast")
        XCTAssertEqual(environment?["ANTHROPIC_CUSTOM_MODEL_OPTION_NAME"], "gpt-5.6-terra-fast")
        XCTAssertEqual(
            environment?["ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION"],
            "Priority-Tier (1,5× Speed, 2,5× Credits) — unterstützt: GPT-5.6 Sol/Terra/Luna, GPT-5.5 und GPT-5.4/Mini"
        )
    }

    func testGPTRouterCoreEnvironmentKeepsModelsPlainWhenFastModeIsDisabled() {
        var builder = AgentCommandBuilder()
        builder.gptBackendEnabledResolver = { true }
        builder.gptPickerModelResolver = { "" }
        builder.gptFastModeEnabledResolver = { false }
        builder.gptRouterPortResolver = { 19_003 }
        builder.gptDefaultModelResolver = { "gpt-5.6-terra" }
        builder.gptSubagentModelResolver = { "" }

        let environment = builder.gptRouterCoreEnvironment()

        XCTAssertEqual(environment?["ANTHROPIC_CUSTOM_MODEL_OPTION"], "gpt-5.6-terra")
        XCTAssertEqual(environment?["ANTHROPIC_CUSTOM_MODEL_OPTION_NAME"], "gpt-5.6-terra")
        XCTAssertEqual(
            environment?["ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION"],
            "Standard-Tier — unterstützt: GPT-5.6 Sol/Terra/Luna, GPT-5.5 und GPT-5.4/Mini"
        )
    }

    func testGPTRouterCoreFallsBackToFastSolForDisallowedSubagentModel() {
        var builder = AgentCommandBuilder()
        builder.gptBackendEnabledResolver = { true }
        builder.gptPickerModelResolver = { "" }
        builder.gptFastModeEnabledResolver = { true }
        builder.gptRouterPortResolver = { 19_004 }
        builder.gptDefaultModelResolver = { "gpt-5.6-sol" }
        builder.gptSubagentModelResolver = { "  gpt-5.6-luna  " }

        XCTAssertEqual(
            builder.gptRouterCoreEnvironment()?["CLAUDE_CODE_SUBAGENT_MODEL"],
            "gpt-5.6-sol-fast"
        )
    }

    func testClaudeGPTRouterWithoutSessionStampKeepsArgumentsAndAddsRouterEnvironment() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { true }
        builder.extraArgumentsResolver = { provider in
            provider == .claude ? ["--dangerously-skip-permissions"] : []
        }
        builder.claudeProfileEnvironmentResolver = { _ in
            ["CLAUDE_CONFIG_DIR": "/profiles/firma"]
        }
        builder.gptBackendEnabledResolver = { true }
        builder.gptPickerModelResolver = { "" }
        builder.gptRouterPortResolver = { 19_002 }
        builder.gptSubagentModelResolver = { "" }
        builder.gptDefaultModelResolver = { "" }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "claude-session",
            title: "Claude",
            hasLaunchedInitialPrompt: true,
            claudeProfileName: "firma"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.arguments, [
            "--dangerously-skip-permissions", "--resume", "claude-session",
        ])
        // Ohne konfiguriertes Standard-Modell registriert das kanonische
        // Modell die /model-Picker-Option; Effort-Steuerung ist immer aktiv.
        XCTAssertEqual(command.environmentOverrides, [
            "CLAUDE_CONFIG_DIR": "/profiles/firma",
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:19002",
            "ANTHROPIC_CUSTOM_MODEL_OPTION": "gpt-5.6-sol-fast",
            "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME": "gpt-5.6-sol-fast",
            "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION": "Priority-Tier (1,5× Speed, 2,5× Credits) — unterstützt: GPT-5.6 Sol/Terra/Luna, GPT-5.5 und GPT-5.4/Mini",
            "CLAUDE_CODE_ALWAYS_ENABLE_EFFORT": "1",
            "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "272000",
            "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "1000000",
            "WHISPERM8_GPT56_CONTEXT_WINDOW": "272000",
        ])
    }

    func testClaudeGPTBackendAddsModelBeforeExtraArgumentsAndMergesEnvironment() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { true }
        builder.extraLaunchArguments = ["--settings", "/tmp/hooks.json"]
        builder.extraArgumentsResolver = { provider in
            provider == .claude ? ["--dangerously-skip-permissions"] : []
        }
        builder.claudeProfileEnvironmentResolver = { _ in
            ["CLAUDE_CONFIG_DIR": "/profiles/firma"]
        }
        builder.gptBackendEnabledResolver = { true }
        builder.gptPickerModelResolver = { "" }
        builder.gptRouterPortResolver = { 19_001 }
        builder.gptSubagentModelResolver = { "" }
        builder.gptDefaultModelResolver = { "" }
        builder.gptContextWindowResolver = { 250_000 }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Claude",
            initialPrompt: "Los",
            claudeProfileName: "firma",
            claudeBackendModel: "gpt-5.6-sol"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.arguments, [
            "--settings", "/tmp/hooks.json",
            "--model", "gpt-5.6-sol-fast",
            "--dangerously-skip-permissions",
            "Los",
        ])
        XCTAssertEqual(command.environmentOverrides, [
            "CLAUDE_CONFIG_DIR": "/profiles/firma",
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:19001",
            "ANTHROPIC_CUSTOM_MODEL_OPTION": "gpt-5.6-sol-fast",
            "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME": "gpt-5.6-sol-fast",
            "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION": "Priority-Tier (1,5× Speed, 2,5× Credits) — unterstützt: GPT-5.6 Sol/Terra/Luna, GPT-5.5 und GPT-5.4/Mini",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "gpt-5.4-mini",
            "CLAUDE_CODE_ALWAYS_ENABLE_EFFORT": "1",
            "CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY": "3",
            "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "250000",
            "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "1000000",
            "WHISPERM8_GPT56_CONTEXT_WINDOW": "250000",
        ])
    }

    func testExperimental372KFreshTerraSessionFallsBackToSolStamp() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.extraArgumentsResolver = { _ in [] }
        builder.claudeProfileEnvironmentResolver = { _ in [:] }
        builder.gptBackendEnabledResolver = { true }
        builder.gptFastModeEnabledResolver = { false }
        builder.gptPickerModelResolver = { "gpt-5.6-terra" }
        builder.gptSubagentModelResolver = { "" }
        builder.gptContextWindowResolver = { 372_000 }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Claude",
            claudeBackendModel: "gpt-5.6-terra"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.arguments, ["--model", "gpt-5.6-sol"])
        XCTAssertEqual(command.environmentOverrides["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "372000")
        XCTAssertEqual(command.environmentOverrides["ANTHROPIC_CUSTOM_MODEL_OPTION"], "gpt-5.6-sol")
    }

    func testClaudeGPTBackendResumeOmitsModelStampAndRouterTuning() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { false }
        builder.extraArgumentsResolver = { _ in ["--verbose"] }
        builder.claudeProfileEnvironmentResolver = { _ in [:] }
        builder.gptBackendEnabledResolver = { true }
        builder.gptPickerModelResolver = { "" }
        builder.gptRouterPortResolver = { 18_766 }
        builder.gptDefaultModelResolver = { "gpt-5.6-sol" }
        builder.gptSubagentModelResolver = { "" }
        builder.gptContextWindowResolver = { 260_000 }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "resume-1",
            title: "Claude",
            hasLaunchedInitialPrompt: true,
            claudeBackendModel: "gpt-5.6-terra"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.arguments, ["--verbose", "--resume", "resume-1"])
        XCTAssertEqual(command.environmentOverrides, [
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:18766",
            "ANTHROPIC_CUSTOM_MODEL_OPTION": "gpt-5.6-sol",
            "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME": "gpt-5.6-sol",
            "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION": "Standard-Tier — unterstützt: GPT-5.6 Sol/Terra/Luna, GPT-5.5 und GPT-5.4/Mini",
            "CLAUDE_CODE_ALWAYS_ENABLE_EFFORT": "1",
            "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "260000",
            "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "1000000",
            "WHISPERM8_GPT56_CONTEXT_WINDOW": "260000",
        ])
        XCTAssertFalse(command.arguments.contains("--model"))
        XCTAssertNil(command.environmentOverrides["ANTHROPIC_AUTH_TOKEN"])
    }

    func testLegacyResumeFindsGPTMemorySuffixBeforeHugeTrailingUserLineWithPlainStamp() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-resume-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: transcript) }
        let hugeUserText = String(repeating: "x", count: 1_200_000)
        let lines = [
            #"{"type":"assistant","message":{"model":"GPT-5.6-TERRA-FAST[1M]","content":[{"type":"text","text":"done"}]}}"#,
            #"{"type":"user","message":{"content":"\#(hugeUserText)"}}"#,
        ].joined(separator: "\n")
        try lines.write(to: transcript, atomically: true, encoding: .utf8)

        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.extraArgumentsResolver = { _ in [] }
        builder.claudeProfileEnvironmentResolver = { _ in [:] }
        builder.gptBackendEnabledResolver = { true }
        builder.gptFastModeEnabledResolver = { false }
        builder.gptPickerModelResolver = { "" }
        builder.gptSubagentModelResolver = { "" }
        builder.claudeTranscriptLocator = { _, _ in transcript }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "legacy-resume",
            title: "Legacy",
            hasLaunchedInitialPrompt: true,
            claudeBackendModel: "gpt-5.6-sol"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.arguments, [
            "--model", "gpt-5.6-terra-fast",
            "--resume", "legacy-resume",
        ])
    }

    func testLegacyResumeDoesNotOverrideLaterClaudeModelSwitch() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-switched-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: transcript) }
        let lines = [
            #"{"type":"assistant","message":{"model":"gpt-5.6-sol[1m]","content":[]}}"#,
            #"{"type":"assistant","message":{"model":"claude-fable-5","content":[]}}"#,
        ].joined(separator: "\n")
        try lines.write(to: transcript, atomically: true, encoding: .utf8)

        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.extraArgumentsResolver = { _ in [] }
        builder.claudeProfileEnvironmentResolver = { _ in [:] }
        builder.gptBackendEnabledResolver = { true }
        builder.gptPickerModelResolver = { "" }
        builder.gptSubagentModelResolver = { "" }
        builder.claudeTranscriptLocator = { _, _ in transcript }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "switched-resume",
            title: "Switched",
            hasLaunchedInitialPrompt: true,
            claudeBackendModel: "gpt-5.6-sol"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.arguments, ["--resume", "switched-resume"])
    }

    func testArgumentsContainResumeFlagRecognizesAllOfficialForms() {
        let officialForms = [
            ["-c"], ["--continue"], ["-r"], ["--resume"], ["--resume=session-1"],
        ]
        for arguments in officialForms {
            XCTAssertTrue(
                AgentCommandBuilder.argumentsContainResumeFlag(arguments),
                "Resume-Form nicht erkannt: \(arguments)"
            )
        }
    }

    func testArgumentsContainResumeFlagRejectsPrefixLookalikes() {
        XCTAssertFalse(AgentCommandBuilder.argumentsContainResumeFlag(["--resumeX", "-continue"]))
        XCTAssertFalse(AgentCommandBuilder.argumentsContainResumeFlag(["--model", "gpt-5.6-sol"]))
    }

    func testClaudeGPTBackendResumeEqualsArgumentSuppressesStampAndTuning() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.extraArgumentsResolver = { _ in ["--resume=restored-session"] }
        builder.claudeProfileEnvironmentResolver = { _ in [:] }
        builder.gptBackendEnabledResolver = { true }
        builder.gptPickerModelResolver = { "" }
        builder.gptRouterPortResolver = { 18_766 }
        builder.gptDefaultModelResolver = { "gpt-5.6-sol" }
        builder.gptSubagentModelResolver = { "" }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Claude",
            claudeBackendModel: "gpt-5.6-terra"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.arguments, ["--resume=restored-session"])
        XCTAssertFalse(command.arguments.contains("--model"))
        XCTAssertNil(command.environmentOverrides["ANTHROPIC_DEFAULT_HAIKU_MODEL"])
        XCTAssertNil(command.environmentOverrides["CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY"])
        XCTAssertEqual(command.environmentOverrides["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "272000")
        XCTAssertEqual(command.environmentOverrides["CLAUDE_CODE_AUTO_COMPACT_WINDOW"], "1000000")
        XCTAssertEqual(command.environmentOverrides["WHISPERM8_GPT56_CONTEXT_WINDOW"], "272000")
        XCTAssertEqual(command.environmentOverrides["ANTHROPIC_BASE_URL"], "http://127.0.0.1:18766")
    }

    func testClaudeGPTBackendForkOmitsModelStamp() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { true }
        builder.extraArgumentsResolver = { _ in [] }
        builder.claudeProfileEnvironmentResolver = { _ in [:] }
        builder.gptBackendEnabledResolver = { true }
        builder.gptPickerModelResolver = { "" }
        builder.gptRouterPortResolver = { 18_766 }
        builder.gptDefaultModelResolver = { "gpt-5.6-sol" }
        builder.gptSubagentModelResolver = { "" }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Claude-Fork",
            forkSourceSessionID: "source-1",
            claudeBackendModel: "gpt-5.6-terra"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.arguments, ["--resume", "source-1", "--fork-session"])
        XCTAssertFalse(command.arguments.contains("--model"))
        XCTAssertEqual(
            command.environmentOverrides["ANTHROPIC_CUSTOM_MODEL_OPTION"],
            "gpt-5.6-sol-fast"
        )
        XCTAssertEqual(command.environmentOverrides["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "272000")
        XCTAssertEqual(command.environmentOverrides["CLAUDE_CODE_AUTO_COMPACT_WINDOW"], "1000000")
        XCTAssertEqual(command.environmentOverrides["WHISPERM8_GPT56_CONTEXT_WINDOW"], "272000")
    }

    func testLegacyForkMigratesTranscriptGPTMemorySuffix() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-fork-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: transcript) }
        try #"{"type":"assistant","message":{"model":"gpt-5.5[1m]","content":[]}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)

        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.extraArgumentsResolver = { _ in [] }
        builder.claudeProfileEnvironmentResolver = { _ in [:] }
        builder.gptBackendEnabledResolver = { true }
        builder.gptFastModeEnabledResolver = { true }
        builder.gptPickerModelResolver = { "" }
        builder.gptSubagentModelResolver = { "" }
        builder.claudeTranscriptLocator = { sessionID, _ in
            sessionID == "legacy-source" ? transcript : nil
        }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Legacy Fork",
            forkSourceSessionID: "legacy-source",
            claudeBackendModel: "gpt-5.6-sol"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.arguments, [
            "--model", "gpt-5.5",
            "--resume", "legacy-source", "--fork-session",
        ])
    }

    func testClaudeGPTBackendKeepsExplicitFastModelWhenToggleIsOff() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { false }
        builder.extraArgumentsResolver = { _ in [] }
        builder.claudeProfileEnvironmentResolver = { _ in [:] }
        builder.gptBackendEnabledResolver = { true }
        builder.gptPickerModelResolver = { "" }
        builder.gptRouterPortResolver = { 18_766 }
        builder.gptSubagentModelResolver = { "" }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Claude",
            claudeBackendModel: "gpt-5.6-sol-fast"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.arguments, ["--model", "gpt-5.6-sol-fast"])
    }

    func testFreshUnknownGPTStampIsNotEmitted() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.extraArgumentsResolver = { _ in [] }
        builder.claudeProfileEnvironmentResolver = { _ in [:] }
        builder.gptBackendEnabledResolver = { true }
        builder.gptPickerModelResolver = { "" }
        builder.gptSubagentModelResolver = { "" }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Unknown",
            claudeBackendModel: "gpt-5.3-codex-spark"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertFalse(command.arguments.contains("--model"))
        XCTAssertNil(command.environmentOverrides["ANTHROPIC_DEFAULT_HAIKU_MODEL"])
    }

    func testClaudeModelOverrideKeepsRouterWideContextInvariants() throws {
        // Der Auto-Compact-Deckel ist absichtlich prozessweit 1M. Das GPT-
        // Modellfenster steckt separat in MAX_CONTEXT und kappt ein natives
        // Fable-/Opus-Modell in derselben Router-Session deshalb nicht.
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { false }
        builder.extraArgumentsResolver = { _ in ["--model", "claude-opus-4-6"] }
        builder.claudeProfileEnvironmentResolver = { _ in [:] }
        builder.gptBackendEnabledResolver = { true }
        builder.gptPickerModelResolver = { "" }
        builder.gptRouterPortResolver = { 18_766 }
        builder.gptSubagentModelResolver = { "" }
        builder.gptContextWindowResolver = { 272_000 }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Claude",
            claudeBackendModel: "gpt-5.6-sol"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.environmentOverrides["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "272000")
        XCTAssertEqual(command.environmentOverrides["CLAUDE_CODE_AUTO_COMPACT_WINDOW"], "1000000")
        XCTAssertEqual(command.environmentOverrides["WHISPERM8_GPT56_CONTEXT_WINDOW"], "272000")

        builder.extraArgumentsResolver = { _ in ["--model", "gpt-5.6-terra"] }
        let gptCommand = try builder.command(for: session, project: project)
        XCTAssertEqual(gptCommand.environmentOverrides["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "272000")
        XCTAssertEqual(gptCommand.environmentOverrides["CLAUDE_CODE_AUTO_COMPACT_WINDOW"], "1000000")
    }

    func testClaudeGPTBackendLeavesPlainUserExtraModelAsLastFlagWinsOptOut() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { true }
        builder.extraArgumentsResolver = { _ in ["--model", "gpt-5.6-sol"] }
        builder.claudeProfileEnvironmentResolver = { _ in [:] }
        builder.gptBackendEnabledResolver = { true }
        builder.gptPickerModelResolver = { "" }
        builder.gptRouterPortResolver = { 18_766 }
        builder.gptSubagentModelResolver = { "" }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Claude",
            claudeBackendModel: "gpt-5.6-terra"
        )

        let command = try builder.command(for: session, project: project)

        // claude parst last-flag-wins: das explizite plain User-`--model`
        // bleibt unveraendert NACH dem fastifizierten GPT-Stempel und gewinnt.
        XCTAssertEqual(command.arguments, [
            "--model", "gpt-5.6-terra-fast", "--model", "gpt-5.6-sol",
        ])
    }

    func testClaudeGPTBackendStripsMemorySuffixFromAllGeneratedAliases() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { true }
        builder.extraArgumentsResolver = { _ in [] }
        builder.claudeProfileEnvironmentResolver = { _ in [:] }
        builder.gptBackendEnabledResolver = { true }
        builder.gptPickerModelResolver = { "gpt-5.6-luna[1M]" }
        builder.gptSubagentModelResolver = { "gpt-5.6-terra-fast[1m]" }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Claude",
            claudeBackendModel: "gpt-5.6-sol[1m]"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.arguments, ["--model", "gpt-5.6-sol-fast"])
        XCTAssertEqual(
            command.environmentOverrides["ANTHROPIC_CUSTOM_MODEL_OPTION"],
            "gpt-5.6-luna-fast"
        )
        XCTAssertEqual(
            command.environmentOverrides["ANTHROPIC_CUSTOM_MODEL_OPTION_NAME"],
            "gpt-5.6-luna-fast"
        )
        XCTAssertEqual(
            command.environmentOverrides["CLAUDE_CODE_SUBAGENT_MODEL"],
            "gpt-5.6-terra-fast"
        )
        XCTAssertFalse(command.arguments.contains { $0.lowercased().contains("[1m]") })
        XCTAssertFalse(command.environmentOverrides.values.contains {
            $0.lowercased().contains("gpt-") && $0.lowercased().contains("[1m]")
        })
    }

    func testClaudeGPTBackendAddsConfiguredSubagentModel() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { true }
        builder.extraArgumentsResolver = { _ in [] }
        builder.claudeProfileEnvironmentResolver = { _ in [:] }
        builder.gptBackendEnabledResolver = { true }
        builder.gptPickerModelResolver = { "" }
        builder.gptRouterPortResolver = { 18_766 }
        builder.gptSubagentModelResolver = { "gpt-5.6-terra" }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Claude"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(
            command.environmentOverrides["CLAUDE_CODE_SUBAGENT_MODEL"],
            "gpt-5.6-terra-fast"
        )
    }

    func testClaudeGPTBackendFastToggleOffKeepsPickerPlainAndFallsBackToPlainSolSubagent() throws {
        // Fast-aus muss ALLE Emissionspunkte plain lassen — nicht nur das
        // Haupt-`--model`, sondern auch Picker-Option und Subagent-Env.
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { false }
        builder.extraArgumentsResolver = { _ in [] }
        builder.claudeProfileEnvironmentResolver = { _ in [:] }
        builder.gptBackendEnabledResolver = { true }
        builder.gptPickerModelResolver = { "" }
        builder.gptRouterPortResolver = { 18_766 }
        builder.gptDefaultModelResolver = { "gpt-5.6-sol" }
        builder.gptSubagentModelResolver = { "gpt-5.6-luna" }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Claude",
            claudeBackendModel: "gpt-5.6-terra"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.arguments, ["--model", "gpt-5.6-terra"])
        XCTAssertEqual(
            command.environmentOverrides["ANTHROPIC_CUSTOM_MODEL_OPTION"],
            "gpt-5.6-sol"
        )
        XCTAssertEqual(
            command.environmentOverrides["CLAUDE_CODE_SUBAGENT_MODEL"],
            "gpt-5.6-sol"
        )
    }

    func testClaudeGPTBackendOmitsWhitespaceOnlySubagentModel() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { false }
        builder.extraArgumentsResolver = { _ in [] }
        builder.claudeProfileEnvironmentResolver = { _ in [:] }
        builder.gptBackendEnabledResolver = { true }
        builder.gptPickerModelResolver = { "" }
        builder.gptRouterPortResolver = { 18_766 }
        builder.gptSubagentModelResolver = { "  \n " }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Claude",
            claudeBackendModel: "gpt-5.6-sol"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertNil(command.environmentOverrides["CLAUDE_CODE_SUBAGENT_MODEL"])
    }

    func testClaudeDirectBackendOmitsConfiguredSubagentModel() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { false }
        builder.extraArgumentsResolver = { _ in [] }
        builder.claudeProfileEnvironmentResolver = { _ in [:] }
        builder.gptBackendEnabledResolver = { false }
        builder.gptSubagentModelResolver = { "gpt-5.6-sol" }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Claude",
            claudeBackendModel: "gpt-5.6-terra"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertNil(command.environmentOverrides["CLAUDE_CODE_SUBAGENT_MODEL"])
    }

    func testClaudeGPTBackendKillSwitchIgnoresExistingSessionStamp() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { false }
        builder.extraArgumentsResolver = { _ in [] }
        builder.claudeProfileEnvironmentResolver = { _ in
            ["CLAUDE_CONFIG_DIR": "/profiles/firma"]
        }
        builder.gptBackendEnabledResolver = { false }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "resume-1",
            title: "Claude",
            hasLaunchedInitialPrompt: true,
            claudeProfileName: "firma",
            claudeBackendModel: "gpt-5.6-sol"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.arguments, ["--resume", "resume-1"])
        XCTAssertEqual(command.environmentOverrides, [
            "CLAUDE_CONFIG_DIR": "/profiles/firma",
        ])
        XCTAssertNil(command.environmentOverrides["CLAUDE_CODE_MAX_CONTEXT_TOKENS"])
        XCTAssertNil(command.environmentOverrides["CLAUDE_CODE_AUTO_COMPACT_WINDOW"])
        XCTAssertNil(command.environmentOverrides["WHISPERM8_GPT56_CONTEXT_WINDOW"])
    }

    func testAgentViewKeepsContextTrioWhileBackgroundAttachOmitsIt() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { true }
        builder.extraArgumentsResolver = { _ in [] }
        builder.claudeProfileEnvironmentResolver = { profile in
            profile == "firma" ? ["CLAUDE_CONFIG_DIR": "/profiles/firma"] : [:]
        }
        builder.gptBackendEnabledResolver = { true }
        builder.gptPickerModelResolver = { "" }
        builder.gptRouterPortResolver = { 18_766 }
        builder.gptSubagentModelResolver = { "gpt-5.6-sol" }
        builder.gptDefaultModelResolver = { "gpt-5.6-terra" }

        let agentView = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Agent View",
            kind: .agentView,
            claudeProfileName: "firma",
            claudeBackendModel: "gpt-5.6-sol"
        )
        let backgroundChat = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Background",
            kind: .backgroundChat,
            backgroundShortID: "abcdef12",
            claudeProfileName: "firma",
            claudeBackendModel: "gpt-5.6-sol"
        )

        let agentViewCommand = try builder.command(for: agentView, project: project)
        let backgroundCommand = try builder.command(for: backgroundChat, project: project)

        let expectedRouterEnvironment = [
            "CLAUDE_CONFIG_DIR": "/profiles/firma",
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:18766",
            "ANTHROPIC_CUSTOM_MODEL_OPTION": "gpt-5.6-terra-fast",
            "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME": "gpt-5.6-terra-fast",
            "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION": "Priority-Tier (1,5× Speed, 2,5× Credits) — unterstützt: GPT-5.6 Sol/Terra/Luna, GPT-5.5 und GPT-5.4/Mini",
            "CLAUDE_CODE_ALWAYS_ENABLE_EFFORT": "1",
            "CLAUDE_CODE_SUBAGENT_MODEL": "gpt-5.6-sol-fast",
            "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "272000",
            "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "1000000",
            "WHISPERM8_GPT56_CONTEXT_WINDOW": "272000",
        ]
        XCTAssertEqual(agentViewCommand.arguments, ["agents"])
        XCTAssertEqual(agentViewCommand.environmentOverrides, expectedRouterEnvironment)
        XCTAssertTrue(agentViewCommand.environmentRemovals.isEmpty)
        XCTAssertEqual(backgroundCommand.arguments, ["attach", "abcdef12"])
        XCTAssertEqual(
            backgroundCommand.environmentRemovals,
            Set(AgentCommandBuilder.gptContextEnvironmentKeys)
        )
        var expectedAttachEnvironment = expectedRouterEnvironment
        for key in AgentCommandBuilder.gptContextEnvironmentKeys {
            expectedAttachEnvironment.removeValue(forKey: key)
            XCTAssertNil(backgroundCommand.environmentOverrides[key])
        }
        XCTAssertEqual(backgroundCommand.environmentOverrides, expectedAttachEnvironment)
        XCTAssertEqual(
            backgroundCommand.environmentOverrides["ANTHROPIC_BASE_URL"],
            "http://127.0.0.1:18766"
        )
        XCTAssertEqual(
            backgroundCommand.environmentOverrides["CLAUDE_CONFIG_DIR"],
            "/profiles/firma"
        )
    }
}

// MARK: - Claude-Account-Profile (CLAUDE_CONFIG_DIR-Injektion)

extension AgentCommandBuilderTests {
    func testClaudeCommandInjectsProfileEnvironment() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { false }
        builder.extraArgumentsResolver = { _ in [] }
        builder.claudeProfileEnvironmentResolver = { profileName in
            profileName.map { ["CLAUDE_CONFIG_DIR": "/profiles/\($0)"] } ?? [:]
        }

        let profileSession = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Chat",
            claudeProfileName: "firma"
        )
        let command = try builder.command(for: profileSession, project: project)
        XCTAssertEqual(command.environmentOverrides, ["CLAUDE_CONFIG_DIR": "/profiles/firma"])

        // Resume behaelt das Profil der Session — nicht das aktive.
        let resumeSession = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "ext-1",
            title: "Chat",
            hasLaunchedInitialPrompt: true,
            claudeProfileName: "firma"
        )
        let resumeCommand = try builder.command(for: resumeSession, project: project)
        XCTAssertEqual(resumeCommand.environmentOverrides, ["CLAUDE_CONFIG_DIR": "/profiles/firma"])
    }

    func testClaudeCommandWithoutProfileHasNoEnvironmentOverrides() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { false }
        builder.extraArgumentsResolver = { _ in [] }
        builder.claudeProfileEnvironmentResolver = { profileName in
            profileName.map { ["CLAUDE_CONFIG_DIR": "/profiles/\($0)"] } ?? [:]
        }

        let mainSession = AgentChatSession(provider: .claude, projectID: project.id, title: "Chat")
        let command = try builder.command(for: mainSession, project: project)
        XCTAssertTrue(command.environmentOverrides.isEmpty)
    }

    func testClaudeResumeFollowsActualTranscriptRootOverStaleStamp() throws {
        // Resume-Selbstheilung: liegt die JSONL real unter einem Profil-Root,
        // der Stempel behauptet aber main (oder umgekehrt), muss der Launch
        // dem realen Ablageort folgen — sonst „No conversation found".
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { false }
        builder.extraArgumentsResolver = { _ in [] }
        builder.claudeProfileEnvironmentResolver = { profileName in
            profileName.map { ["CLAUDE_CONFIG_DIR": "/profiles/\($0)"] } ?? [:]
        }
        // Transcript liegt real im PowerUser-Root …
        builder.claudeTranscriptLocator = { sessionID, _ in
            URL(fileURLWithPath: "/Users/test/.claude-profiles/PowerUser/projects/-repo/\(sessionID).jsonl")
        }

        // … aber die Session ist auf main (nil) gestempelt.
        let staleMainSession = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "ext-1",
            title: "Chat",
            hasLaunchedInitialPrompt: true,
            claudeProfileName: nil
        )
        let command = try builder.command(for: staleMainSession, project: project)
        XCTAssertEqual(command.environmentOverrides, ["CLAUDE_CONFIG_DIR": "/profiles/PowerUser"])
        XCTAssertTrue(command.arguments.contains("--resume"))

        // Umgekehrt: Stempel „firma", Transcript real unter main → kein Override.
        builder.claudeTranscriptLocator = { sessionID, _ in
            URL(fileURLWithPath: "/Users/test/.claude/projects/-repo/\(sessionID).jsonl")
        }
        let staleProfileSession = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "ext-2",
            title: "Chat",
            hasLaunchedInitialPrompt: true,
            claudeProfileName: "firma"
        )
        let mainCommand = try builder.command(for: staleProfileSession, project: project)
        XCTAssertTrue(mainCommand.environmentOverrides.isEmpty)
    }

    func testClaudeResumeKeepsStampWhenTranscriptNotLocatable() throws {
        // Kein Transcript auffindbar (noch nicht geschrieben) → Stempel
        // bleibt maßgeblich, wie bisher.
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { false }
        builder.extraArgumentsResolver = { _ in [] }
        builder.claudeProfileEnvironmentResolver = { profileName in
            profileName.map { ["CLAUDE_CONFIG_DIR": "/profiles/\($0)"] } ?? [:]
        }
        builder.claudeTranscriptLocator = { _, _ in nil }

        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "ext-3",
            title: "Chat",
            hasLaunchedInitialPrompt: true,
            claudeProfileName: "firma"
        )
        let command = try builder.command(for: session, project: project)
        XCTAssertEqual(command.environmentOverrides, ["CLAUDE_CONFIG_DIR": "/profiles/firma"])
    }

    func testCodexCommandNeverGetsClaudeProfileEnvironment() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { false }
        builder.extraArgumentsResolver = { _ in [] }
        builder.codexServiceTierResolver = { .standard }
        builder.claudeProfileEnvironmentResolver = { _ in
            XCTFail("Codex-Launches duerfen den Claude-Profil-Resolver nicht aufrufen")
            return [:]
        }

        let codexSession = AgentChatSession(provider: .codex, projectID: project.id, title: "Codex")
        let command = try builder.command(for: codexSession, project: project)
        XCTAssertTrue(command.environmentOverrides.isEmpty)
    }
}

// MARK: - Context-Profil-Env (extraEnvironmentOverrides)

extension AgentCommandBuilderTests {
    /// Prioritaetskette der Env-Overrides: Profil-Env (Context-Profil) <
    /// Account-CLAUDE_CONFIG_DIR < Router-Env. Reservierte Keys werden zwar
    /// schon im ClaudeContextSettingsBuilder gefiltert — dieser Test sichert
    /// die zweite Verteidigungslinie im Builder-Merge ab.
    func testContextProfileEnvironmentLosesAgainstAccountAndRouter() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { false }
        builder.extraArgumentsResolver = { _ in [] }
        builder.extraEnvironmentOverrides = [
            "ENABLE_CLAUDEAI_MCP_SERVERS": "false",
            "CLAUDE_CONFIG_DIR": "/tmp/kapern",          // verliert gegen Account
            "ANTHROPIC_BASE_URL": "http://evil"          // verliert gegen Router
        ]
        builder.claudeProfileEnvironmentResolver = { _ in
            ["CLAUDE_CONFIG_DIR": "/profiles/firma"]
        }
        builder.gptBackendEnabledResolver = { true }
        builder.gptPickerModelResolver = { "" }
        builder.gptRouterPortResolver = { 19_003 }
        builder.gptSubagentModelResolver = { "" }
        builder.gptDefaultModelResolver = { "" }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Claude",
            claudeProfileName: "firma"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.environmentOverrides["ENABLE_CLAUDEAI_MCP_SERVERS"], "false")
        XCTAssertEqual(command.environmentOverrides["CLAUDE_CONFIG_DIR"], "/profiles/firma")
        XCTAssertEqual(command.environmentOverrides["ANTHROPIC_BASE_URL"], "http://127.0.0.1:19003")
    }

    /// Ohne Router und ohne Account-Profil kommt das Profil-Env pur durch.
    func testContextProfileEnvironmentPassesThroughWithoutConflicts() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { false }
        builder.extraArgumentsResolver = { _ in [] }
        builder.extraEnvironmentOverrides = ["ENABLE_TOOL_SEARCH": "auto"]
        builder.claudeProfileEnvironmentResolver = { _ in [:] }
        builder.gptBackendEnabledResolver = { false }
        let session = AgentChatSession(provider: .claude, projectID: project.id, title: "Claude")

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.environmentOverrides, ["ENABLE_TOOL_SEARCH": "auto"])
    }

    /// Der Resume-Selbstheilungs-Pfad (Stempel ≠ realer Transcript-Root)
    /// darf das Context-Profil-Env nicht verlieren.
    func testContextProfileEnvironmentSurvivesResumeRepair() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.gptFastModeEnabledResolver = { false }
        builder.extraArgumentsResolver = { _ in [] }
        builder.extraEnvironmentOverrides = ["ENABLE_TOOL_SEARCH": "auto"]
        builder.claudeProfileEnvironmentResolver = { profileName in
            profileName.map { ["CLAUDE_CONFIG_DIR": "/profiles/\($0)"] } ?? [:]
        }
        // Transcript liegt real im Haupt-Account → Selbstheilung auf nil-Profil.
        builder.claudeTranscriptLocator = { _, _ in
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".claude/projects/x/ext-9.jsonl")
        }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "ext-9",
            title: "Chat",
            hasLaunchedInitialPrompt: true,
            claudeProfileName: "firma"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.environmentOverrides, ["ENABLE_TOOL_SEARCH": "auto"])
    }
}
