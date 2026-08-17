import Foundation

/// `whisperm8 chats _prompt-guard [--events <pfad>]` — internes Subcommand,
/// das die App als `UserPromptSubmit`-Hook in die generierten Claude-Settings
/// einträgt (`ClaudeHookSettingsBuilder`). Nicht in der Hilfe gelistet; das
/// Unterstrich-Präfix markiert es als Vertragsbestandteil der Hook-Bridge,
/// nicht der User-CLI.
///
/// Liest das Hook-JSON von stdin (`{"prompt": …, "transcript_path": …}`),
/// entscheidet über `ChatsPromptGuard` und antwortet per Exit-Code — bei
/// `UserPromptSubmit` heißt Exit 2: Prompt blocken und verwerfen, stderr geht
/// an den User. Zwei Zusatzwege:
/// - **Retry nach Fehl-Turn:** Scheiterte die Erstausführung dieses Prompts
///   nachweislich an einem Modell-Fehler (Transcript-Tail, z. B. „Prompt is
///   too long"), passiert die Wiedervorlage ohne Token (Vorfall 2026-08-17 #2).
/// - **Block-Event:** Bei Block wird eine `WhisperM8PromptGuardBlock`-Zeile
///   in das Event-File der Hook-Bridge appended (`--events`) — die App leert
///   daraufhin den Composer (der geblockte Text bliebe sonst kleben) und
///   nimmt das fälschliche „working" des geblockten Submits zurück.
///
/// Alles andere (auch jeder Parse-/IO-Fehler) ist Exit 0: Der Guard schützt
/// vor versehentlicher Wiedervorlage, er darf niemals normales Arbeiten
/// blockieren (fail-open).
enum ChatsPromptGuardCommand {
    /// Nur der Datei-Tail wird gelesen — Transcripts können >50 MB werden,
    /// der relevante letzte Turn liegt immer am Ende.
    static let transcriptTailBytes = 262_144

    static func run(_ arguments: [String]) -> Int32 {
        var eventsPath: String?
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--events", index + 1 < arguments.count {
                eventsPath = arguments[index + 1]
                index += 1
            }
            index += 1
        }

        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let prompt = object["prompt"] as? String, !prompt.isEmpty else {
            return ChatsCLIExit.ok
        }
        let transcriptPath = object["transcript_path"] as? String
        let store = SendDeliveryTokenStore()
        let verdict = ChatsPromptGuard.decide(
            prompt: prompt,
            consumeToken: { store.consume(promptText: $0) },
            failedTurnEvidence: { candidate in
                guard let transcriptPath,
                      let tail = readTail(path: transcriptPath) else { return false }
                return PromptGuardRetryProbe.failedTurnEvidence(
                    prompt: candidate, transcriptTail: tail)
            })
        switch verdict {
        case .allow:
            return ChatsCLIExit.ok
        case .block(let reason):
            CLIIO.err(reason)
            if let eventsPath {
                appendBlockEvent(to: eventsPath, hookInput: object)
            }
            // Exit 2 = UserPromptSubmit-Block (Claude-Code-Hook-Vertrag) —
            // bewusst NICHT ChatsCLIExit (das sind User-CLI-Semantiken).
            return 2
        }
    }

    /// Letzte `transcriptTailBytes` der Datei, ab der ersten vollständigen
    /// Zeile (ein angeschnittener JSONL-Anfang würde nur still ignoriert,
    /// kostet aber nichts, ihn sauber zu kappen).
    static func readTail(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(transcriptTailBytes) ? size - UInt64(transcriptTailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              var text = String(data: data, encoding: .utf8) else { return nil }
        if start > 0, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        return text
    }

    /// Appendet die Block-Zeile ins Event-File der Hook-Bridge — gleiche
    /// Transportstrecke wie der `(cat; echo)`-Append-Hook, `O_APPEND` ist
    /// für kleine Writes atomar. Fehler sind still (das Composer-Leeren ist
    /// Komfort, nie Voraussetzung für den Block).
    static func appendBlockEvent(to path: String, hookInput: [String: Any]) {
        var event: [String: Any] = ["hook_event_name": "WhisperM8PromptGuardBlock"]
        if let sessionID = hookInput["session_id"] as? String {
            event["session_id"] = sessionID
        }
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
