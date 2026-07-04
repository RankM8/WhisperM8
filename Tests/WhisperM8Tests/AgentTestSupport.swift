import Foundation
import XCTest

// Gemeinsame Test-Helper für die Agent-Chats-Testdateien.

/// Echte JSONL-Zeilen aus einem `codex exec --json`-Lauf (codex-cli 0.142.5,
/// 2026-07-04). Von Parser-, Runner- und Supervisor-Tests geteilt, damit alle
/// gegen dasselbe verifizierte Format testen. NICHT von Hand "verschönern" —
/// bei einem codex-Update neu aufnehmen und ersetzen.
enum CodexExecFixtures {
    static let threadStarted = #"{"type":"thread.started","thread_id":"019f2efe-a948-7ad3-8f21-afd79af17271"}"#
    static let turnStarted = #"{"type":"turn.started"}"#
    static let itemErrorNote = #"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Skill descriptions were shortened to fit the 2% skills context budget."}}"#
    static let itemAgentMessage = #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Ich lese kurz die Datei im aktuellen Workspace und fasse sie in einem Satz zusammen."}}"#
    static let itemCommandStarted = #"{"type":"item.started","item":{"id":"item_4","type":"command_execution","command":"/bin/zsh -lc \"ls -la readme.txt README.txt 2>/dev/null\"","aggregated_output":"","exit_code":null,"status":"in_progress"}}"#
    static let itemCommandFailed = #"{"type":"item.completed","item":{"id":"item_2","type":"command_execution","command":"/bin/zsh -lc \"rg --files\"","aggregated_output":"zsh:1: command not found: rg\n","exit_code":127,"status":"failed"}}"#
    static let itemCommandCompleted = #"{"type":"item.completed","item":{"id":"item_4","type":"command_execution","command":"/bin/zsh -lc \"sed -n '1,120p' readme.txt\"","aggregated_output":"hello whisperm8\n","exit_code":0,"status":"completed"}}"#
    static let finalAgentMessage = #"{"type":"item.completed","item":{"id":"item_5","type":"agent_message","text":"In `readme.txt` steht: `hello whisperm8`."}}"#
    static let turnCompleted = #"{"type":"turn.completed","usage":{"input_tokens":52453,"cached_input_tokens":39040,"output_tokens":319,"reasoning_output_tokens":0}}"#

    // Synthetisch (Form laut Doku/Defensive — im Fixture-Lauf nicht aufgetreten):
    static let turnFailedNested = #"{"type":"turn.failed","error":{"message":"stream disconnected"}}"#
    static let topLevelError = #"{"type":"error","message":"unexpected server error"}"#

    /// Ein kompletter erfolgreicher Turn in Stream-Reihenfolge.
    static let successfulTurnLines: [String] = [
        threadStarted, turnStarted, itemAgentMessage,
        itemCommandStarted, itemCommandCompleted,
        finalAgentMessage, turnCompleted,
    ]
}

extension XCTestCase {
    func makeTempProjectDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8ProjectTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func makeTempStoreURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8Tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("AgentSessions.json")
    }
}
