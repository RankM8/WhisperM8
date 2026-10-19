import XCTest
@testable import WhisperM8

/// LR-AU-031: „+"-Menü je nach Schalter, Startwert für Bestands- und Neunutzer.
final class AgentAdvancedFeaturesTests: XCTestCase {
    private func preferences() -> AppPreferences {
        let suite = "advanced-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppPreferences(defaults: defaults)
    }

    func testMenuOffShowsOnlyClaudeBeforeCodex() {
        XCTAssertEqual(NewChatMenuPlan.items(advancedEnabled: false, gptBackendEnabled: false), [.claudeChat, .codexChat])
    }

    func testMenuOffKeepsGPTWhenBackendIsOn() {
        XCTAssertEqual(NewChatMenuPlan.items(advancedEnabled: false, gptBackendEnabled: true), [.claudeChat, .codexChat, .gptChat])
    }

    func testMenuOnKeepsEveryFeatureUnderAdvanced() {
        XCTAssertEqual(
            NewChatMenuPlan.items(advancedEnabled: true, gptBackendEnabled: true),
            [.claudeChat, .codexChat, .gptChat, .advanced([.terminal, .backgroundAgent, .agentView, .subAgentLibrary])])
    }

    func testInitialValueFollowsExistingSessions() {
        XCTAssertTrue(AgentAdvancedFeatures.initialValue(workspaceHasSessions: true))
        XCTAssertFalse(AgentAdvancedFeatures.initialValue(workspaceHasSessions: false))
    }

    func testResolveAtLaunchDecidesOnceAndStores() {
        let prefs = preferences()
        XCTAssertFalse(prefs.agentAdvancedFeaturesEnabled)
        XCTAssertTrue(AgentAdvancedFeatures.resolveAtLaunch(preferences: prefs, workspaceHasSessions: { true }))
        XCTAssertTrue(prefs.agentAdvancedFeaturesEnabled)
        // Zweiter Start: Entscheidung steht, die Workspace-Datei wird nicht mehr gelesen.
        var read = false
        XCTAssertTrue(AgentAdvancedFeatures.resolveAtLaunch(preferences: prefs, workspaceHasSessions: { read = true; return false }))
        XCTAssertFalse(read)
    }

    func testFreshInstallStaysOffAndUserChoiceWins() {
        let prefs = preferences()
        XCTAssertFalse(AgentAdvancedFeatures.resolveAtLaunch(preferences: prefs, workspaceHasSessions: { false }))
        prefs.agentAdvancedFeaturesEnabled = true
        XCTAssertTrue(AgentAdvancedFeatures.resolveAtLaunch(preferences: prefs, workspaceHasSessions: { false }))
    }
}

final class AgentAdvancedFeaturesSettingsTests: XCTestCase {
    func testNewChatOptionsHideAgentViewWhenAdvancedOff() {
        XCTAssertEqual(AgentChatsWorkspaceSettingsTab.newChatOptions(advanced: false, current: "claude"), ["claude", "codex"])
        XCTAssertEqual(AgentChatsWorkspaceSettingsTab.newChatOptions(advanced: true, current: "claude"), ["claude", "claude-agents", "codex"])
    }

    func testStoredAgentViewChoiceStaysVisible() {
        XCTAssertTrue(AgentChatsWorkspaceSettingsTab.newChatOptions(advanced: false, current: "claude-agents").contains("claude-agents"))
    }
}
