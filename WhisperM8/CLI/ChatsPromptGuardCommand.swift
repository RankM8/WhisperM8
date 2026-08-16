import Foundation

/// `whisperm8 chats _prompt-guard` — internes Subcommand, das die App als
/// `UserPromptSubmit`-Hook in die generierten Claude-Settings einträgt
/// (`ClaudeHookSettingsBuilder`). Nicht in der Hilfe gelistet; das
/// Unterstrich-Präfix markiert es als Vertragsbestandteil der Hook-Bridge,
/// nicht der User-CLI.
///
/// Liest das Hook-JSON von stdin (`{"prompt": …}`), entscheidet über
/// `ChatsPromptGuard` und antwortet per Exit-Code — bei `UserPromptSubmit`
/// heißt Exit 2: Prompt blocken und verwerfen, stderr geht an den User.
/// Alles andere (auch jeder Parse-Fehler) ist Exit 0: Der Guard schützt vor
/// versehentlicher Wiedervorlage, er darf niemals normales Arbeiten
/// blockieren (fail-open).
enum ChatsPromptGuardCommand {
    static func run(_ arguments: [String]) -> Int32 {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let prompt = object["prompt"] as? String, !prompt.isEmpty else {
            return ChatsCLIExit.ok
        }
        let store = SendDeliveryTokenStore()
        switch ChatsPromptGuard.decide(prompt: prompt, consumeToken: { store.consume(promptText: $0) }) {
        case .allow:
            return ChatsCLIExit.ok
        case .block(let reason):
            CLIIO.err(reason)
            // Exit 2 = UserPromptSubmit-Block (Claude-Code-Hook-Vertrag) —
            // bewusst NICHT ChatsCLIExit (das sind User-CLI-Semantiken).
            return 2
        }
    }
}
