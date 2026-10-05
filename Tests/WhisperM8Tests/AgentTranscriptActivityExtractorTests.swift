import XCTest
@testable import WhisperM8

/// Stand-Zeile des Tab-Switchers aus dem Transcript-Tail. Fixtures sind klein
/// und synthetisch, aber in der Form echter Zeilen (Claude: eine Zeile pro
/// Content-Block; Codex: `response_item`/`event_msg` mit `payload`).
final class AgentTranscriptActivityExtractorTests: XCTestCase {
    // MARK: - Fixture-Bausteine

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func claudeUser(_ text: String, isMeta: Bool = false) -> String {
        var object: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": text],
        ]
        if isMeta { object["isMeta"] = true }
        return json(object)
    }

    private func claudeToolResult(_ content: String = "ok") -> String {
        json([
            "type": "user",
            "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "toolu_1", "content": content],
            ]],
        ])
    }

    private func claudeAssistant(_ blocks: [[String: Any]], stopReason: String? = "tool_use") -> String {
        var message: [String: Any] = ["role": "assistant", "content": blocks]
        message["stop_reason"] = stopReason ?? NSNull()
        return json(["type": "assistant", "message": message])
    }

    private func claudeTool(_ name: String, _ input: [String: Any]) -> String {
        claudeAssistant([["type": "tool_use", "id": "toolu_1", "name": name, "input": input]])
    }

    private func claudeText(_ text: String) -> String {
        claudeAssistant([["type": "text", "text": text]], stopReason: "end_turn")
    }

    private func claudeThinking() -> String {
        claudeAssistant([["type": "thinking", "thinking": "überlegt"]])
    }

    private func claudeMeta(_ type: String) -> String {
        json(["type": type, "sessionId": "abc"])
    }

    private func codex(_ type: String, _ payload: [String: Any]) -> String {
        json(["timestamp": "2026-10-02T10:00:00.000Z", "type": type, "payload": payload])
    }

    private func codexFunctionCall(_ name: String, _ arguments: [String: Any]) -> String {
        codex("response_item", ["type": "function_call", "name": name, "arguments": json(arguments), "call_id": "c1"])
    }

    private func codexAssistant(_ text: String) -> String {
        codex("response_item", ["type": "message", "role": "assistant",
                                "content": [["type": "output_text", "text": text]]])
    }

    private func codexUserPrompt(_ text: String) -> String {
        codex("event_msg", ["type": "user_message", "message": text])
    }

    private func codexNoise() -> [String] {
        [
            codex("response_item", ["type": "reasoning", "summary": [], "encrypted_content": "gAAA"]),
            codex("event_msg", ["type": "token_count", "info": NSNull()]),
            codex("response_item", ["type": "function_call_output", "call_id": "c1", "output": "fertig"]),
            codex("event_msg", ["type": "item_completed"]),
        ]
    }

    private func tail(_ lines: [String]) -> String {
        lines.joined(separator: "\n") + "\n"
    }

    private func claude(_ lines: [String]) -> AgentSessionActivity? {
        AgentTranscriptActivityExtractor.activity(in: tail(lines), provider: .claude)
    }

    private func codex(_ lines: [String]) -> AgentSessionActivity? {
        AgentTranscriptActivityExtractor.activity(in: tail(lines), provider: .codex)
    }

    // MARK: - Claude: Tabellenzeilen

    func testClaudeArbeitetZeigtLetztesToolMitDateiname() {
        let activity = claude([
            claudeUser("Bitte den Store umbauen"),
            claudeThinking(),
            claudeTool("Read", ["file_path": "/Users/dev/repo/Sources/Old.swift"]),
            claudeToolResult(),
            claudeTool("Edit", ["replace_all": false, "file_path": "/Users/dev/repo/Sources/Store.swift",
                                "old_string": "a", "new_string": "b"]),
            claudeMeta("attachment"),
        ])
        XCTAssertEqual(activity?.detail, .tool(name: "Edit", argument: "Store.swift"))
        XCTAssertEqual(activity?.line(for: .working), "› Edit Store.swift")
    }

    func testClaudeBashNachToolErgebnisBleibtStand() {
        let activity = claude([
            claudeUser("Tests laufen lassen"),
            claudeTool("Bash", ["command": "swift test", "description": "Tests"]),
            claudeToolResult(String(repeating: "Ausgabe ", count: 200)),
            claudeMeta("system"),
        ])
        XCTAssertEqual(activity?.line(for: .working), "› Bash swift test")
    }

    func testClaudeSchreibtAntwort() {
        let activity = claude([
            claudeUser("Was ist los?"),
            claudeTool("Bash", ["command": "git status"]),
            claudeToolResult(),
            claudeText("Der Baum ist sauber. Keine Änderungen offen."),
        ])
        XCTAssertEqual(activity?.line(for: .working), "› schreibt Antwort")
    }

    func testClaudeFrageAusAskUserQuestion() {
        let activity = claude([
            claudeUser("Mach mal"),
            claudeTool("AskUserQuestion", ["questions": [[
                "question": "Welchen Branch soll ich nehmen?",
                "header": "Branch", "multiSelect": false,
                "options": [["label": "main", "description": "x"]],
            ]]]),
        ])
        XCTAssertEqual(activity?.detail, .question("Welchen Branch soll ich nehmen?"))
        XCTAssertEqual(activity?.line(for: .awaitingInput), "Frage: Welchen Branch soll ich nehmen?")
        var withHook = activity
        withHook?.awaitingKind = .question
        XCTAssertEqual(withHook?.line(for: .awaitingInput), "Frage: Welchen Branch soll ich nehmen?")
    }

    func testClaudeMehrzeiligeFrageNurErsteZeile() {
        let activity = claude([
            claudeTool("AskUserQuestion", ["questions": [[
                "question": "\nSoll ich pushen?\nDer Branch hat 3 Commits.\n\nAlternativ warten.",
                "header": "Push",
            ]]]),
        ])
        XCTAssertEqual(activity?.line(for: .awaitingInput), "Frage: Soll ich pushen?")
    }

    func testClaudePlanFreigabeAusHook() {
        var activity = claude([
            claudeTool("ExitPlanMode", ["plan": "# Plan\n1. Alles umbauen"]),
        ])
        XCTAssertEqual(activity?.detail, .tool(name: "ExitPlanMode", argument: nil))
        activity?.awaitingKind = .planApproval
        XCTAssertEqual(activity?.line(for: .awaitingInput), "Plan zur Freigabe")
        // Auch ohne Hook-Art kein roher Plan-Text in der Zeile.
        activity?.awaitingKind = nil
        XCTAssertEqual(activity?.line(for: .working), "Plan zur Freigabe")
    }

    func testClaudeBerechtigungKombiniertHookUndTail() {
        var activity = claude([
            claudeTool("Bash", ["command": "git push origin main"]),
        ])
        activity?.awaitingKind = .permission
        activity?.awaitingToolName = "Bash"
        XCTAssertEqual(activity?.line(for: .awaitingInput), "Freigabe: Bash git push origin main")

        // Hook nennt ein anderes Tool als der Tail → nur der Hook-Name.
        activity?.awaitingToolName = "WebFetch"
        XCTAssertEqual(activity?.line(for: .awaitingInput), "Freigabe: WebFetch")

        // Hook ohne Tail.
        let hookOnly = AgentSessionActivity(awaitingKind: .permission, awaitingToolName: "Write")
        XCTAssertEqual(hookOnly.line(for: .awaitingInput), "Freigabe: Write")
    }

    func testClaudeIdleZeigtErstenSatzDerLetztenAntwort() {
        let activity = claude([
            claudeUser("Status?"),
            claudeThinking(),
            claudeText("## Ergebnis\n\nDie Migration ist durch, z. B. der Store. Danach kommen die Tests."),
            claudeMeta("system"),
            claudeMeta("last-prompt"),
        ])
        XCTAssertEqual(activity?.line(for: .idle), "Die Migration ist durch, z. B. der Store.")
    }

    func testAntwortMitMarkdownHervorhebung() {
        let activity = claude([claudeText("**Fertig**: alle `42` Tests grün! Weiter geht's.")])
        XCTAssertEqual(activity?.line(for: .idle), "Fertig: alle 42 Tests grün!")
    }

    func testGestopptUndFehlerKommenAusDemStatus() {
        let activity = claude([claudeText("Fertig.")])
        XCTAssertEqual(activity?.line(for: .stopped), "gestoppt")
        XCTAssertEqual(activity?.line(for: .errored), "Fehler")
        XCTAssertEqual(AgentSessionActivity().line(for: .stopped), "gestoppt")
    }

    func testMcpToolNameWirdGekuerzt() {
        let activity = claude([claudeTool("mcp__claude-in-chrome__navigate", ["url": "https://example.com/a"])])
        XCTAssertEqual(activity?.detail, .tool(name: "navigate", argument: "https://example.com/a"))
    }

    // MARK: - Claude: Randfälle

    func testAbgeschnitteneErsteZeileWirdIgnoriert() {
        let full = claudeTool("Bash", ["command": "make test"])
        let cut = String(full.dropFirst(25))
        let text = cut + "\n" + claudeMeta("system") + "\n"
        XCTAssertNil(AgentTranscriptActivityExtractor.activity(in: text, provider: .claude))

        let withHit = cut + "\n" + claudeTool("Grep", ["pattern": "TODO", "path": "/repo/src"]) + "\n"
        XCTAssertEqual(
            AgentTranscriptActivityExtractor.activity(in: withHit, provider: .claude)?.line(for: .working),
            "› Grep TODO")
    }

    func testTailOhneTrefferLiefertNil() {
        XCTAssertNil(claude([claudeMeta("mode"), claudeMeta("permission-mode"), claudeThinking()]))
        XCTAssertNil(claude([]))
        XCTAssertNil(codex(codexNoise()))
    }

    func testNutzerPromptIstTurnGrenze() {
        // Direkt nach dem Prompt zeigt der Chat NICHT das Tool des vorigen Turns.
        let activity = claude([
            claudeTool("Bash", ["command": "alter befehl"]),
            claudeToolResult(),
            claudeText("Alte Antwort."),
            claudeUser("Neuer Auftrag"),
            claudeThinking(),
        ])
        XCTAssertNil(activity)
    }

    func testMetaNutzerZeileIstKeineGrenze() {
        let activity = claude([
            claudeTool("Bash", ["command": "ls"]),
            claudeUser("<system-reminder>x</system-reminder>", isMeta: true),
        ])
        XCTAssertEqual(activity?.line(for: .working), "› Bash ls")
    }

    func testSehrLangerBashBefehlWirdEinzeiligUndGekappt() {
        let heredoc = "cat > /tmp/x.swift <<'EOF'\n" + String(repeating: "let wert = 1\n", count: 5_000) + "EOF"
        let activity = claude([claudeTool("Bash", ["command": heredoc])])
        let line = activity?.line(for: .working)
        XCTAssertNotNil(line)
        XCTAssertLessThanOrEqual(line?.count ?? 0, AgentSessionActivity.maxLength)
        XCTAssertFalse(line?.contains("\n") ?? true)
        XCTAssertTrue(line?.hasSuffix("…") ?? false)
        XCTAssertTrue(line?.hasPrefix("› Bash cat > x.swift <<'EOF' let wert = 1") ?? false, line ?? "")
    }

    func testPfadeImBefehlWerdenAufDateinamenReduziert() {
        let activity = claude([claudeTool("Bash", [
            "command": "sed -n '1,80p' /Users/dev/repos/app/Sources/Feature/Store.swift \"~/docs/plan.md\" ./scripts/run.sh",
        ])])
        XCTAssertEqual(activity?.line(for: .working), "› Bash sed -n '1,80p' Store.swift plan.md run.sh")
        // Relative Angaben ohne führendes / bleiben unverändert.
        let relative = claude([claudeTool("Bash", ["command": "swift test --filter Foo/bar"])])
        XCTAssertEqual(relative?.line(for: .working), "› Bash swift test --filter Foo/bar")
    }

    func testPfadeInDerAntwortWerdenGekuerzt() {
        let activity = claude([claudeText("Gespeichert unter /Users/dev/Downloads/bericht.pdf. Fertig.")])
        XCTAssertEqual(activity?.line(for: .idle), "Gespeichert unter bericht.pdf.")
    }

    func testLangeAntwortWirdGekappt() {
        let sentence = String(repeating: "Wort ", count: 40) + "Ende."
        let line = claude([claudeText(sentence)])?.line(for: .idle)
        XCTAssertEqual(line?.count, AgentSessionActivity.maxLength)
        XCTAssertTrue(line?.hasSuffix("…") ?? false)
    }

    // MARK: - Codex

    func testCodexExecCommandWirdBash() {
        let activity = codex([
            codexUserPrompt("Bau das"),
            codexFunctionCall("exec_command", ["cmd": "swift build", "workdir": "/repo", "yield_time_ms": 1000]),
        ] + codexNoise())
        XCTAssertEqual(activity?.line(for: .working), "› Bash swift build")
    }

    func testCodexShellArrayOhneBashPraefix() {
        let activity = codex([
            codexFunctionCall("shell", ["command": ["bash", "-lc", "rg -n Store /repo/Sources"]]),
        ])
        XCTAssertEqual(activity?.line(for: .working), "› Bash rg -n Store Sources")
    }

    func testCodexApplyPatchZeigtDatei() {
        let activity = codex([
            codex("response_item", ["type": "custom_tool_call", "name": "apply_patch", "call_id": "c2",
                                    "input": "*** Begin Patch\n*** Update File: /repo/Sources/Store.swift\n@@\n-a\n+b\n*** End Patch"]),
        ])
        XCTAssertEqual(activity?.line(for: .working), "› Edit Store.swift")
    }

    func testCodexExecJavaScriptMitInneremShellAufruf() {
        let script = "const r = await tools.exec_command({cmd:\"ffmpeg -i /tmp/in.mov \\\"out.mp4\\\"\", yield_time_ms: 1000});\ntext(r);"
        let activity = codex([
            codex("response_item", ["type": "custom_tool_call", "name": "exec", "call_id": "c3", "input": script]),
        ])
        XCTAssertEqual(activity?.line(for: .working), "› Bash ffmpeg -i in.mov \"out.mp4\"")
    }

    func testCodexAntwortUndTurnGrenze() {
        let done = codex([
            codexUserPrompt("Prüf das"),
            codexFunctionCall("exec_command", ["cmd": "git diff"]),
            codexAssistant("Alles geprüft. Zwei Stellen sind offen."),
            codex("event_msg", ["type": "agent_message", "message": "Alles geprüft. Zwei Stellen sind offen."]),
            codex("event_msg", ["type": "task_complete"]),
        ] + codexNoise())
        XCTAssertEqual(done?.line(for: .idle), "Alles geprüft.")
        XCTAssertEqual(done?.line(for: .working), "› schreibt Antwort")

        let fresh = codex([
            codexAssistant("Alte Antwort."),
            codexUserPrompt("Neuer Auftrag"),
            codex("response_item", ["type": "reasoning", "summary": []]),
        ])
        XCTAssertNil(fresh)
    }

    func testCodexEntwicklerNachrichtIstKeinStand() {
        let activity = codex([
            codex("response_item", ["type": "message", "role": "developer",
                                    "content": [["type": "input_text", "text": "Anweisungen"]]]),
        ])
        XCTAssertNil(activity)
    }

    func testCodexWarteZustandOhneHookArt() {
        // Codex kennt keine Warte-Art — die Zeile zeigt, was der Tail weiß.
        let activity = codex([codexFunctionCall("exec_command", ["cmd": "git push"])])
        XCTAssertEqual(activity?.line(for: .awaitingInput), "› Bash git push")
    }

    // MARK: - Laufzeit

    /// Schranke für den Poll-Pfad: ein voller 64-KB-Tail OHNE Treffer (der
    /// teuerste Fall — kein früher Abbruch, jede Zeile wird geprüft). Läuft
    /// in der App off-main im `sidebarStatusPoll`-Intervall.
    func testVollerTailOhneTrefferBleibtInnerhalbDesBudgets() {
        // Claude: viele große Tool-Ergebnisse + Meta-Zeilen, kein Treffer.
        var claudeLines: [String] = []
        var size = 0
        while size < AgentSessionRuntimeWatcher.tailReadBytes {
            let line = size % 3 == 0 ? claudeThinking() : claudeToolResult(String(repeating: "x", count: 900))
            claudeLines.append(line)
            size += line.utf8.count + 1
        }
        let claudeTail = tail(claudeLines)
        // Codex: Reasoning/Output-Rauschen, kein Treffer.
        var codexLines: [String] = []
        size = 0
        while size < AgentSessionRuntimeWatcher.tailReadBytes {
            for line in codexNoise() {
                codexLines.append(line)
                size += line.utf8.count + 1
            }
        }
        let codexTail = tail(codexLines)
        // Zusätzlich: Claude-Tail aus lauter kleinen Assistant-Zeilen, die
        // geparst werden müssen (Thinking) — der teuerste Parse-Fall.
        var parseHeavy: [String] = []
        size = 0
        while size < AgentSessionRuntimeWatcher.tailReadBytes {
            let line = claudeThinking()
            parseHeavy.append(line)
            size += line.utf8.count + 1
        }
        let parseHeavyTail = tail(parseHeavy)

        // CPU-Zeit des Threads statt Wandzeit, bester von fünf Durchgängen —
        // siehe `TestTiming`. Unter Last riss die Wandzeit das Budget ohne
        // jede Code-Änderung.
        let runs = 10
        var perTail = TimeInterval.infinity
        for _ in 0..<5 {
            let (_, seconds) = TestTiming.threadCPUSeconds {
                for _ in 0..<runs {
                    XCTAssertNil(AgentTranscriptActivityExtractor.activity(in: claudeTail, provider: .claude))
                    XCTAssertNil(AgentTranscriptActivityExtractor.activity(in: codexTail, provider: .codex))
                    XCTAssertNil(AgentTranscriptActivityExtractor.activity(in: parseHeavyTail, provider: .claude))
                }
            }
            perTail = min(perTail, seconds / Double(runs * 3))
        }
        print("activity_extractor_64kb_ms=\(String(format: "%.3f", perTail * 1000))")
        // Großzügig: soll eine echte Regression (quadratisch, Voll-Parse
        // jeder Tool-Ausgabe) fangen, nicht Maschinen-Schwankungen.
        XCTAssertLessThan(perTail, 0.02, "64-KB-Tail dauerte \(perTail * 1000) ms")
    }
}
