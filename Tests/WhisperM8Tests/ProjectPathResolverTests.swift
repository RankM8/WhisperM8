import XCTest
@testable import WhisperM8

final class ProjectPathResolverTests: XCTestCase {
    private func mode(id: String, projectAccess: ProjectAccessPolicy) -> OutputMode {
        OutputMode(
            id: id,
            name: id,
            shortLabel: id,
            kind: .builtIn,
            templateID: PostProcessingTemplate.promptID,
            isEnabled: true,
            isDefault: false,
            projectAccess: projectAccess
        )
    }

    func testOffModeNeverResolvesAProjectPath() {
        XCTAssertNil(
            ProjectPathResolver.resolvedProjectPath(
                mode: mode(id: OutputMode.promptID, projectAccess: .off),
                agentChatProjectPath: "/repo/chat",
                defaultProjectPath: "/repo/default"
            )
        )
    }

    func testPromptPlusPrefersAgentChatProjectAndFallsBackToDefault() {
        let promptPlus = mode(id: OutputMode.promptPlusID, projectAccess: .readOnly)

        XCTAssertEqual(
            ProjectPathResolver.resolvedProjectPath(
                mode: promptPlus,
                agentChatProjectPath: "/repo/chat",
                defaultProjectPath: "/repo/default"
            ),
            "/repo/chat"
        )
        XCTAssertEqual(
            ProjectPathResolver.resolvedProjectPath(
                mode: promptPlus,
                agentChatProjectPath: nil,
                defaultProjectPath: "/repo/default"
            ),
            "/repo/default"
        )
        // Graceful degrade: ohne auflösbaren Pfad läuft der Modus projektlos weiter.
        XCTAssertNil(
            ProjectPathResolver.resolvedProjectPath(
                mode: promptPlus,
                agentChatProjectPath: "   ",
                defaultProjectPath: ""
            )
        )
    }

    func testTaskAlwaysUsesDefaultProjectPathNeverTheAgentChat() {
        let task = mode(id: OutputMode.taskID, projectAccess: .readOnly)

        // Task-Verhalten unverändert: latestTaskAgentSession() matcht die
        // Session über den Default-Pfad — der Agent-Chat-Pfad darf das
        // Arbeitsverzeichnis nicht umbiegen.
        XCTAssertEqual(
            ProjectPathResolver.resolvedProjectPath(
                mode: task,
                agentChatProjectPath: "/repo/chat",
                defaultProjectPath: "/repo/default"
            ),
            "/repo/default"
        )
        // Leerer Default-Pfad wird zu nil normalisiert (temp dir statt URL("")).
        XCTAssertNil(
            ProjectPathResolver.resolvedProjectPath(
                mode: task,
                agentChatProjectPath: "/repo/chat",
                defaultProjectPath: ""
            )
        )
    }

    func testCustomModeWithReadOnlyAccessUsesSameChainAsPromptPlus() {
        let custom = mode(id: "custom-ticket-plus", projectAccess: .readOnly)

        XCTAssertEqual(
            ProjectPathResolver.resolvedProjectPath(
                mode: custom,
                agentChatProjectPath: " /repo/chat ",
                defaultProjectPath: "/repo/default"
            ),
            "/repo/chat"
        )
    }
}
