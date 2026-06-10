import Foundation
import XCTest
@testable import WhisperM8

final class ClaudeHookBridgeTests: XCTestCase {
    // MARK: - Claude Hook Bridge

    func testClaudeHookSettingsBuilderProducesValidJSON() throws {
        let data = try ClaudeHookSettingsBuilder.serializedSettings(eventFilePath: "/tmp/events.jsonl")
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed?["hooks"])
        let hooks = parsed?["hooks"] as? [String: Any]
        // Alle vier getrackten Events muessen verdrahtet sein — sonst kriegt
        // die Bridge fuer Background-Agents kein "Needs input"-Signal.
        XCTAssertNotNil(hooks?["SessionStart"])
        XCTAssertNotNil(hooks?["SessionEnd"])
        XCTAssertNotNil(hooks?["PreToolUse"])
        XCTAssertNotNil(hooks?["Notification"])
        XCTAssertEqual(
            Set(ClaudeHookSettingsBuilder.trackedEventNames),
            ["SessionStart", "SessionEnd", "PreToolUse", "Notification"]
        )
    }

    func testClaudeHookSettingsBuilderUsesSameAppendCommandForAllEvents() throws {
        // Wir wollen sicherstellen, dass jede Event-Liste denselben
        // Append-Command nutzt — sonst landen Events in unterschiedlichen
        // Dateien und der DispatchSource-Reader sieht nur einen Teil.
        let data = try ClaudeHookSettingsBuilder.serializedSettings(eventFilePath: "/tmp/events.jsonl")
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hooks = parsed?["hooks"] as? [String: Any] ?? [:]
        var commands: Set<String> = []
        for name in ClaudeHookSettingsBuilder.trackedEventNames {
            let entries = hooks[name] as? [[String: Any]] ?? []
            for entry in entries {
                let hookList = entry["hooks"] as? [[String: Any]] ?? []
                for hook in hookList {
                    if let cmd = hook["command"] as? String { commands.insert(cmd) }
                }
            }
        }
        XCTAssertEqual(commands.count, 1, "all events must share the same append command, got \(commands)")
    }

    func testClaudeHookSettingsBuilderEscapesQuotesInPath() {
        let cmd = ClaudeHookSettingsBuilder.appendCommand(eventFilePath: "/tmp/with\"quote.jsonl")
        XCTAssertTrue(cmd.contains("\\\"quote.jsonl"))
        // Wir wollen ausserdem die Datei in Double-Quotes haben.
        XCTAssertTrue(cmd.hasPrefix("(cat; echo) >> \""))
    }

    func testClaudeHookEventStoreParsesSessionStartLine() {
        let line = "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"abc-123\",\"cwd\":\"/tmp/repo\",\"transcript_path\":\"/tmp/x.jsonl\"}"
        let event = ClaudeHookEventStore.parseLine(line)
        XCTAssertEqual(event?.hookEventName, .sessionStart)
        XCTAssertEqual(event?.sessionID, "abc-123")
        XCTAssertEqual(event?.cwd, "/tmp/repo")
    }

    func testClaudeHookEventStoreParsesSessionEndWithResumeReason() {
        let line = "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"old\",\"reason\":\"resume\"}"
        let event = ClaudeHookEventStore.parseLine(line)
        XCTAssertEqual(event?.hookEventName, .sessionEnd)
        XCTAssertEqual(event?.reason, "resume")
    }

    func testClaudeHookEventStoreParsesPreToolUseLine() {
        let line = "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"s1\"}"
        let event = ClaudeHookEventStore.parseLine(line)
        XCTAssertEqual(event?.hookEventName, .preToolUse)
        XCTAssertEqual(event?.sessionID, "s1")
    }

    func testClaudeHookEventStoreParsesNotificationLine() {
        let line = "{\"hook_event_name\":\"Notification\",\"session_id\":\"s1\"}"
        let event = ClaudeHookEventStore.parseLine(line)
        XCTAssertEqual(event?.hookEventName, .notification)
    }

    func testClaudeHookEventStoreIgnoresInvalidLine() {
        XCTAssertNil(ClaudeHookEventStore.parseLine("not json"))
        XCTAssertNil(ClaudeHookEventStore.parseLine(""))
    }

    func testClaudeHookEventStoreTailReadsIncrementally() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ClaudeHookEventStore()

        let line1 = "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"first\"}\n"
        try line1.write(to: url, atomically: true, encoding: .utf8)
        let events1 = store.readNewEvents(from: url)
        XCTAssertEqual(events1.count, 1)
        XCTAssertEqual(events1.first?.sessionID, "first")

        // Append zweite Zeile — nur die soll im naechsten Read sichtbar sein.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let line2 = "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"first\",\"reason\":\"resume\"}\n"
        handle.write(line2.data(using: .utf8)!)
        try handle.close()

        let events2 = store.readNewEvents(from: url)
        XCTAssertEqual(events2.count, 1)
        XCTAssertEqual(events2.first?.hookEventName, .sessionEnd)
        XCTAssertEqual(events2.first?.reason, "resume")
    }

    func testClaudeHookPathsAreUnderAppSupport() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WhisperM8HookPaths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ClaudeHookPaths(rootDirectory: root)
        let id = UUID()
        XCTAssertTrue(paths.settingsFileURL(localSessionID: id).path.contains("claude-hooks"))
        XCTAssertTrue(paths.eventFileURL(localSessionID: id).path.contains("claude-session-events"))
        XCTAssertTrue(paths.settingsFileURL(localSessionID: id).lastPathComponent.hasPrefix(id.uuidString))
    }
}
