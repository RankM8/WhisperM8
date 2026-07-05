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

/// Echte JSONL-Zeilen aus Codex-Rollout-Dateien (`~/.codex/sessions/…`,
/// codex-cli 0.142.5, 2026-07-05). Grundlage für den CodexTranscriptReader:
/// Tool-Aufrufe existieren dort NUR als `response_item` (function_call /
/// function_call_output), Assistant-Text ist DOPPELT vorhanden
/// (`event_msg/agent_message` ≙ `response_item/message role=assistant`,
/// gleiche phase commentary|final_answer) und `reasoning` ist verschlüsselt
/// (encrypted_content, summary in der Praxis leer). Lange Payloads sind
/// gekürzt, Feldnamen/Struktur unverändert. Bei codex-Updates neu aufnehmen.
enum CodexRolloutFixtures {
    static let sessionMeta = #"{"timestamp": "2026-07-04T22:19:54.964Z", "type": "session_meta", "payload": {"session_id": "019f2f37-812e-7cb0-adf3-4074a7b7b946", "id": "019f2f37-812e-7cb0-adf3-4074a7b7b946", "timestamp": "2026-07-04T22:19:54.591Z", "cwd": "/Users/giulianocosta/repos/whisperm8", "originator": "codex_exec", "cli_version": "0.142.5", "source": "exec"}}"#
    static let taskStarted = #"{"timestamp": "2026-07-04T22:19:54.965Z", "type": "event_msg", "payload": {"type": "task_started", "turn_id": "019f2f37-8284-7911-bd3f-ed67ab571371", "started_at": 1783203594, "model_context_window": 258400}}"#
    static let turnContext = #"{"timestamp": "2026-07-04T22:19:57.357Z", "type": "turn_context", "payload": {"turn_id": "019f2f37-8284-7911-bd3f-ed67ab571371", "cwd": "/Users/giulianocosta/repos/whisperm8", "model": "gpt-5.5", "effort": "medium", "summary": "auto"}}"#
    static let userMessage = #"{"timestamp": "2026-07-04T22:19:57.449Z", "type": "event_msg", "payload": {"type": "user_message", "message": "Test-Lauf. Reviewe die Codex-Subagent-CLI-Implementierung auf offensichtliche Bugs. Nur Analyse, keine Edits.", "images": [], "local_images": [], "text_elements": []}}"#
    /// Instruktions-Injektion (AGENTS.md etc.) — role user, aber KEIN echter Prompt.
    static let responseItemUserMessage = ##"{"timestamp": "2026-07-04T22:19:57.356Z", "type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "# AGENTS.md instructions for /Users/giulianocosta/repos/whisperm8"}]}}"##
    static let responseItemDeveloperMessage = #"{"timestamp": "2026-07-04T22:19:57.356Z", "type": "response_item", "payload": {"type": "message", "role": "developer", "content": [{"type": "input_text", "text": "<permissions instructions>read-only</permissions instructions>"}]}}"#
    static let reasoningEncrypted = #"{"timestamp": "2026-07-04T22:19:59.365Z", "type": "response_item", "payload": {"type": "reasoning", "id": "rs_01b8d69b64fee860016a49870e86c081919d1c595a49941610", "summary": [], "encrypted_content": "gAAAAABqSYcP3PNwLBKKKTr0N6fiSvD2LquF5pjX"}}"#
    static let agentMessageCommentary = #"{"timestamp": "2026-07-04T22:20:02.794Z", "type": "event_msg", "payload": {"type": "agent_message", "message": "Ich lese gezielt die beiden Implementierungen, damit die Review auf konkreten Codepfaden basiert.", "phase": "commentary", "memory_citation": null}}"#
    /// Duplikat der commentary-Message im response_item-Strom (Dedupe-Fall!).
    static let responseItemAssistantCommentary = #"{"timestamp": "2026-07-04T22:20:02.795Z", "type": "response_item", "payload": {"type": "message", "id": "msg_01b8d69b64fee860016a49870f5948819183a46d78d598ebc7", "role": "assistant", "content": [{"type": "output_text", "text": "Ich lese gezielt die beiden Implementierungen, damit die Review auf konkreten Codepfaden basiert."}], "phase": "commentary"}}"#
    static let functionCall = #"{"timestamp": "2026-07-04T22:20:02.796Z", "type": "response_item", "payload": {"type": "function_call", "id": "fc_01b8d69b64fee860016a498712c5c88191b162e78170faf95d", "name": "exec_command", "arguments": "{\"cmd\":\"sed -n '1,260p' WhisperM8/CLI/AgentCLICommand.swift\",\"workdir\":\"/Users/giulianocosta/repos/whisperm8\",\"yield_time_ms\":10000,\"max_output_tokens\":20000}", "call_id": "call_inBcNU2GxXHVmpmz10I4CFm7"}}"#
    static let functionCallOutput = #"{"timestamp": "2026-07-04T22:20:02.885Z", "type": "response_item", "payload": {"type": "function_call_output", "call_id": "call_inBcNU2GxXHVmpmz10I4CFm7", "output": "Chunk ID: 7dc909\nWall time: 0.0000 seconds\nProcess exited with code 0\nOriginal token count: 2472\nOutput:\nimport Foundation\n\n// MARK: - Dispatch\n"}}"#
    // Synthetisch (Struktur wie oben, Exit-Code ≠ 0 im Fixture-Lauf nicht aufgetreten):
    static let functionCallOutputFailed = #"{"timestamp": "2026-07-04T22:20:03.101Z", "type": "response_item", "payload": {"type": "function_call_output", "call_id": "call_inBcNU2GxXHVmpmz10I4CFm8", "output": "Chunk ID: 7dc90a\nWall time: 0.0100 seconds\nProcess exited with code 127\nOutput:\nzsh:1: command not found: rg\n"}}"#
    static let toolSearchCall = #"{"timestamp": "2026-07-04T23:30:02.624Z", "type": "response_item", "payload": {"type": "tool_search_call", "id": "tsc_06ae178875c7e3e0016a49977a54d88191bd309a89bb204d04", "call_id": "call_5Pc44wjl9IvaNTA035WHwzGm", "status": "completed", "execution": "client", "arguments": {"query": "computer-use", "limit": 8}}}"#
    static let tokenCount = #"{"timestamp": "2026-07-04T22:20:02.934Z", "type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {"input_tokens": 18162, "cached_input_tokens": 2432, "output_tokens": 351, "reasoning_output_tokens": 50, "total_tokens": 18513}}}}"#
    static let agentMessageFinal = #"{"timestamp": "2026-07-04T22:20:38.660Z", "type": "event_msg", "payload": {"type": "agent_message", "message": "{\"status\":\"success\",\"summary\":\"Review abgeschlossen, keine Edits.\",\"filesChanged\":[],\"commits\":[],\"testsRun\":null,\"openQuestions\":[]}", "phase": "final_answer", "memory_citation": null}}"#
    static let taskComplete = #"{"timestamp": "2026-07-04T22:20:38.665Z", "type": "event_msg", "payload": {"type": "task_complete", "turn_id": "019f2f37-8284-7911-bd3f-ed67ab571371", "last_agent_message": "{\"status\":\"success\"}", "completed_at": 1783203638, "duration_ms": 43778}}"#

    /// Ein kompletter Turn in echter Datei-Reihenfolge (inkl. Duplikat +
    /// Skip-Typen) — Basis für Reader-Tests.
    static let fullTurnLines: [String] = [
        sessionMeta, taskStarted, responseItemDeveloperMessage,
        responseItemUserMessage, turnContext, userMessage,
        reasoningEncrypted, agentMessageCommentary,
        responseItemAssistantCommentary, functionCall, functionCallOutput,
        tokenCount, agentMessageFinal, taskComplete,
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
