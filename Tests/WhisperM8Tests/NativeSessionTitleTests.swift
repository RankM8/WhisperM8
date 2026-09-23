import Foundation
import XCTest
@testable import WhisperM8

final class NativeSessionTitleTests: XCTestCase {
    func testClaudePrefersRenameOverAITitleOverFirstPromptAndTakesTheLastEntry() {
        let jsonl = [
            #"{"type":"ai-title","aiTitle":"Alter Titel","sessionId":"s"}"#,
            #"{"type":"user","message":{"role":"user","content":"Baue den Login um"}}"#,
            #"{"type":"ai-title","aiTitle":"Login Umbau","sessionId":"s"}"#,
        ].joined(separator: "\n")
        XCTAssertEqual(NativeSessionTitle.claudeTitle(fromJSONL: jsonl), "Login Umbau", "letzter ai-title gilt")
        let renamed = jsonl + "\n" + #"{"type":"custom-title","customTitle":"auth-refactor","sessionId":"s"}"#
        XCTAssertEqual(NativeSessionTitle.claudeTitle(fromJSONL: renamed), "auth-refactor", "/rename gewinnt")
    }

    func testClaudeFallsBackToFirstRealPromptSkippingCommandsImagesAndToolResults() {
        let jsonl = [
            #"{"type":"user","message":{"role":"user","content":"<local-command-caveat>Caveat: The messages below …</local-command-caveat>"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/model</command-name>"}}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"Meta-Eintrag"}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Image #1] \n\nWas ist da los mit der Websuche im Buchhaltungs-Chat, bitte prüfen und beheben"}]}}"#,
        ].joined(separator: "\n")
        XCTAssertEqual(
            NativeSessionTitle.claudeTitle(fromJSONL: jsonl),
            "Was ist da los mit der Websuche im Buchhaltungs-Chat, bitte…"
        )
        XCTAssertNil(NativeSessionTitle.claudeTitle(fromJSONL: #"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#))
        XCTAssertNil(NativeSessionTitle.claudeTitle(fromJSONL: "kaputt\n{nicht json"))
    }

    func testCodexUsesFirstRealUserPromptNotContextBlocks() {
        let jsonl = [
            #"{"type":"session_meta","payload":{"id":"abc"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n<cwd>/x</cwd>"}]}}"#,
            ##"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /x"}]}}"##,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"KONTEXT: ListM8 Outreach prüfen"}]}}"#,
        ].joined(separator: "\n")
        XCTAssertEqual(NativeSessionTitle.codexTitle(fromJSONL: jsonl), "KONTEXT: ListM8 Outreach prüfen")
        XCTAssertEqual(
            NativeSessionTitle.codexTitle(fromJSONL: #"{"type":"event_msg","payload":{"type":"user_message","message":"Repo-Inventur starten"}}"#),
            "Repo-Inventur starten"
        )
    }

    func testLargeTranscriptReadsHeadAndTailOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-title-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        var content = #"{"type":"ai-title","aiTitle":"Oben","sessionId":"s"}"# + "\n"
        let filler = #"{"type":"assistant","message":{"content":"\#(String(repeating: "x", count: 1000))"}}"# + "\n"
        content += String(repeating: filler, count: 4000)  // ~4 MB, größer als Head+Tail
        content += #"{"type":"custom-title","customTitle":"Unten umbenannt","sessionId":"s"}"# + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(NativeSessionTitle.resolve(provider: .claude, transcriptURL: url), "Unten umbenannt")
    }
}
