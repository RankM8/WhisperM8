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

    func testIgnoresPureActivityEvents() {
        // Aktivitäts-Hooks erzeugen keine Mitteilung; der Status kommt aus der Registry.
        let data = settingsJSON("""
        {
          "PreCompact": [ { "hooks": [ { "type": "command", "command": "echo compact" } ] } ],
          "PostToolUse": [ { "matcher": "*", "hooks": [ { "type": "command", "command": "echo post" } ] } ],
          "PostToolUseFailure": [ { "hooks": [ { "type": "command", "command": "echo fail" } ] } ],
          "UserPromptSubmit": [ { "hooks": [ { "type": "command", "command": "echo prompt" } ] } ],
          "SessionStart": [ { "hooks": [ { "type": "command", "command": "echo start" } ] } ],
          "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "echo bash" } ] } ]
        }
        """)

        let findings = ExternalClaudeHooksInspector.overlappingHooks(settingsData: data, source: "settings.json")
        XCTAssertTrue(findings.isEmpty, "\(findings)")
    }

    func testFlagsNotificationAndPermissionHooks() {
        let data = settingsJSON("""
        {
          "Notification": [ { "hooks": [ { "type": "command", "command": "osascript -e 'display notification'" } ] } ],
          "PermissionRequest": [ { "matcher": "*", "hooks": [ { "type": "command", "command": "say bitte" } ] } ]
        }
        """)

        let findings = ExternalClaudeHooksInspector.overlappingHooks(settingsData: data, source: "settings.json")
        XCTAssertEqual(findings.map(\.eventName), ["Notification", "PermissionRequest"])
    }

    /// Echter Fall vom 05.11.2026: Superset-Hooks in `~/.claude/settings.json`
    /// tun nur mit gesetztem `SUPERSET_HOME_DIR` etwas, in WhisperM8-Chats also nichts.
    func testGuardedHooksAreIgnoredWhenTheirVariableIsMissing() {
        let superset = #"[ -n \"$SUPERSET_HOME_DIR\" ] && [ -x \"$SUPERSET_HOME_DIR/hooks/notify.sh\" ] && SUPERSET_AGENT_ID=claude \"$SUPERSET_HOME_DIR/hooks/notify.sh\" || true"#
        let data = settingsJSON("""
        {
          "PermissionRequest": [ { "matcher": "*", "hooks": [ { "type": "command", "command": "\(superset)" } ] } ],
          "Stop": [ { "hooks": [ { "type": "command", "command": "\(superset)" } ] } ]
        }
        """)

        XCTAssertTrue(ExternalClaudeHooksInspector.overlappingHooks(
            settingsData: data, source: "settings.json", environment: ["PATH": "/usr/bin"]
        ).isEmpty)
        XCTAssertTrue(ExternalClaudeHooksInspector.overlappingHooks(
            settingsData: data, source: "settings.json", environment: ["SUPERSET_HOME_DIR": ""]
        ).isEmpty)
        XCTAssertEqual(ExternalClaudeHooksInspector.overlappingHooks(
            settingsData: data, source: "settings.json", environment: ["SUPERSET_HOME_DIR": "/opt/superset"]
        ).count, 2, "Ist die Variable gesetzt, wirkt der Hook und wird gemeldet")
    }

    func testGuardVariableDetection() {
        XCTAssertEqual(ExternalClaudeHooksInspector.guardVariable(in: #"[ -n "$FOO" ] && run"#), "FOO")
        XCTAssertEqual(ExternalClaudeHooksInspector.guardVariable(in: #"[[ -n "${FOO_BAR}" ]] && run"#), "FOO_BAR")
        XCTAssertEqual(ExternalClaudeHooksInspector.guardVariable(in: #"test -n "$FOO" && run"#), "FOO")
        XCTAssertEqual(ExternalClaudeHooksInspector.guardVariable(in: #"[ -n "${FOO:-}" ] && run"#), "FOO")
        XCTAssertNil(ExternalClaudeHooksInspector.guardVariable(in: "node notify.js"))
        XCTAssertNil(ExternalClaudeHooksInspector.guardVariable(in: #"run && [ -n "$FOO" ]"#), "Nur ein führender Wächter zählt")
        XCTAssertNil(ExternalClaudeHooksInspector.guardVariable(in: #"[ -z "$FOO" ] && run"#), "-z ist kein Wächter für Abwesenheit")
    }

    /// Review Stufe 0, Befund 2: Nur wenn hinter dem Wächter nichts mehr
    /// unbedingt läuft, ist der Hook ohne die Variable wirkungslos.
    func testGuardOnlySilencesWhenNothingRunsUnconditionally() {
        let inactive = [
            #"[ -n "$TMUX" ] && tmux display-message done"#,
            #"[ -n "$TMUX" ] && tmux display-message done || true"#,
            #"[ -n "$TMUX" ] && tmux display-message done || :"#,
            #"[ -n "$TMUX" ] && notify.sh >/dev/null 2>&1 || true"#,
            #"[ -n "$TMUX" ] && notify.sh &> /dev/null"#,
            #"[ -n "$TMUX" ] && notify.sh | tee -a log &"#,
            #"[ -n "${TMUX:-}" ] && tmux display-message done"#,
        ]
        for command in inactive {
            XCTAssertTrue(ExternalClaudeHooksInspector.isInactive(command: command, environment: [:]), command)
        }
        let active = [
            #"[ -n "$TMUX" ] && tmux display-message done || osascript -e 'display notification'"#,
            #"[ -n "$TMUX" ] && tmux display-message done; afplay ping.aiff"#,
            "[ -n \"$TMUX\" ] && tmux display-message done\nafplay ping.aiff",
            #"[ -n "$TMUX" ] && tmux display-message done & afplay ping.aiff"#,
            #"[ -n "${TMUX:-x}" ] && tmux display-message done"#,
        ]
        for command in active {
            XCTAssertFalse(ExternalClaudeHooksInspector.isInactive(command: command, environment: [:]), command)
        }
    }

    /// Variablen, die WhisperM8 oder Claude dem Hook mitgeben, und der
    /// `env`-Block der Settings gelten als gesetzt.
    func testGuardVariablesProvidedToChatHooksCountAsSet() throws {
        for variable in ["WHISPERM8_SESSION_ID", "CLAUDE_PROJECT_DIR", "CLAUDE_CODE_ENTRYPOINT"] {
            XCTAssertFalse(ExternalClaudeHooksInspector.isInactive(
                command: #"[ -n "$\#(variable)" ] && notify.sh"#, environment: [:]), variable)
        }

        let guarded = #"[ -n \"$MY_NOTIFY\" ] && notify.sh"#
        let sameFile = Data("""
        { "env": {"MY_NOTIFY": "1"},
          "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "\(guarded)" } ] } ] } }
        """.utf8)
        XCTAssertEqual(ExternalClaudeHooksInspector.overlappingHooks(
            settingsData: sameFile, source: "settings.json").count, 1)

        // env-Block in settings.json, Hook in settings.local.json.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("hooks-inspector-\(UUID().uuidString)", isDirectory: true)
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{ "env": {"MY_NOTIFY": "1"} }"#.utf8).write(to: claudeDir.appendingPathComponent("settings.json"))
        try Data("""
        { "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "\(guarded)" } ] } ] } }
        """.utf8).write(to: claudeDir.appendingPathComponent("settings.local.json"))

        XCTAssertEqual(ExternalClaudeHooksInspector.inspectUserSettings(home: home, environment: [:]).count, 1)
    }

    func testPreToolUseCountsOnlyForQuestionTools() {
        XCTAssertTrue(ExternalClaudeHooksInspector.canNotify(eventName: "PreToolUse", matcher: "ExitPlanMode"))
        XCTAssertTrue(ExternalClaudeHooksInspector.canNotify(eventName: "PreToolUse", matcher: "AskUserQuestion|ExitPlanMode"))
        XCTAssertFalse(ExternalClaudeHooksInspector.canNotify(eventName: "PreToolUse", matcher: "Bash|Edit"))
        XCTAssertFalse(ExternalClaudeHooksInspector.canNotify(eventName: "PreToolUse", matcher: nil))
        XCTAssertTrue(ExternalClaudeHooksInspector.canNotify(eventName: "Stop", matcher: nil))
        XCTAssertFalse(ExternalClaudeHooksInspector.canNotify(eventName: "PostToolUse", matcher: "AskUserQuestion"))
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
        try settingsJSON(#"{"Notification": [{"hooks": [{"type": "command", "command": "b"}]}]}"#)
            .write(to: claudeDir.appendingPathComponent("settings.local.json"))

        let findings = ExternalClaudeHooksInspector.inspectUserSettings(home: home, environment: [:])

        XCTAssertEqual(findings.count, 2)
        XCTAssertEqual(Set(findings.map(\.source)), ["settings.json", "settings.local.json"])
    }
}
