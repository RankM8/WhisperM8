import XCTest
@testable import WhisperM8

final class ExternalClaudeHooksInspectorTests: XCTestCase {
    private func settingsJSON(_ hooks: String) -> Data {
        Data("""
        { "env": {"FOO": "1"}, "hooks": \(hooks) }
        """.utf8)
    }

    func testFindsOverlappingHooksWithMatcherAndPreview() {
        let data = settingsJSON("""
        {
          "Stop": [
            { "hooks": [ { "type": "command", "command": "node notify.js done" } ] }
          ],
          "PreToolUse": [
            { "matcher": "AskUserQuestion",
              "hooks": [ { "type": "command", "command": "node notify.js waiting" } ] }
          ]
        }
        """)

        let findings = ExternalClaudeHooksInspector.overlappingHooks(settingsData: data, source: "settings.json")

        XCTAssertEqual(findings.count, 2)
        XCTAssertEqual(findings.first?.eventName, "PreToolUse") // alphabetisch sortiert
        XCTAssertEqual(findings.first?.matcher, "AskUserQuestion")
        XCTAssertEqual(findings.first?.commandPreview, "node notify.js waiting")
        XCTAssertEqual(findings.last?.eventName, "Stop")
        XCTAssertNil(findings.last?.matcher)
    }

    func testIgnoresEventsWhisperM8DoesNotTrack() {
        let data = settingsJSON("""
        {
          "PreCompact": [
            { "hooks": [ { "type": "command", "command": "echo compact" } ] }
          ]
        }
        """)

        let findings = ExternalClaudeHooksInspector.overlappingHooks(settingsData: data, source: "settings.json")
        XCTAssertTrue(findings.isEmpty, "PreCompact wird nicht getrackt → kein Konflikt")
    }

    func testFlagsPostToolUseFailureAsTracked() {
        // Seit PostToolUseFailure registriert ist (Aktivitäts-Signal auch bei
        // Tool-Fehlern), muss der Inspector fremde Hooks darauf melden.
        let data = settingsJSON("""
        {
          "PostToolUseFailure": [
            { "hooks": [ { "type": "command", "command": "echo fail" } ] }
          ]
        }
        """)

        let findings = ExternalClaudeHooksInspector.overlappingHooks(settingsData: data, source: "settings.json")
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.eventName, "PostToolUseFailure")
    }

    func testLongCommandsAreTruncatedForPreview() {
        let longCommand = String(repeating: "x", count: 200)
        let data = settingsJSON("""
        { "Stop": [ { "hooks": [ { "type": "command", "command": "\(longCommand)" } ] } ] }
        """)

        let findings = ExternalClaudeHooksInspector.overlappingHooks(settingsData: data, source: "settings.json")
        XCTAssertEqual(findings.first?.commandPreview.count, ExternalClaudeHooksInspector.commandPreviewLength + 1)
        XCTAssertTrue(findings.first?.commandPreview.hasSuffix("…") == true)
    }

    func testMalformedOrMissingHooksYieldNoFindings() {
        XCTAssertTrue(ExternalClaudeHooksInspector.overlappingHooks(
            settingsData: Data("not json".utf8), source: "settings.json"
        ).isEmpty)
        XCTAssertTrue(ExternalClaudeHooksInspector.overlappingHooks(
            settingsData: Data("{}".utf8), source: "settings.json"
        ).isEmpty)
        XCTAssertTrue(ExternalClaudeHooksInspector.overlappingHooks(
            settingsData: settingsJSON(#"{"Stop": "kaputt"}"#), source: "settings.json"
        ).isEmpty)
    }

    func testInspectUserSettingsReadsBothFiles() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("hooks-inspector-\(UUID().uuidString)", isDirectory: true)
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try settingsJSON(#"{"Stop": [{"hooks": [{"type": "command", "command": "a"}]}]}"#)
            .write(to: claudeDir.appendingPathComponent("settings.json"))
        try settingsJSON(#"{"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "b"}]}]}"#)
            .write(to: claudeDir.appendingPathComponent("settings.local.json"))

        let findings = ExternalClaudeHooksInspector.inspectUserSettings(home: home)

        XCTAssertEqual(findings.count, 2)
        XCTAssertEqual(Set(findings.map(\.source)), ["settings.json", "settings.local.json"])
    }
}
