import Foundation

/// Stempelt beim Resume nativer Claude-Sessions das `[1m]`-Suffix zurück an
/// die Modell-ID. Grund ist gemessen (2026-08-19, CLI 2.1.235):
///
/// Claude Code entscheidet das Kontextfenster in `Esd()` und prüft als erstes
/// `jw(e)` — und `jw` testet **ausschließlich den String** auf `[1m]`
/// (`/\[1m\]/i.test(e)`). Transcripts speichern die Modell-ID aber immer
/// suffixlos (`claude-fable-5`), auch wenn die Session mit `fable[1m]` lief.
/// Greifen dann auch die Metadaten-Pfade `vB()`/`fK()` nicht — weil die
/// Modell-Caches leer sind, was CLI-Updates regelmäßig verursachen
/// (`modelAccessCache: []` in `.claude.json`) — fällt `Esd()` auf den
/// Fallback `UOr = 200000` zurück. Die Session läuft dann mit 200k statt 1M
/// und lehnt Prompts mit „Prompt is too long" ab.
///
/// **Was dieser Stempel NICHT löst** (Messung 2026-08-19): Ist der
/// account-weite Latch `longContext1mCreditsBlocked` gesetzt — nach
/// erschöpftem 1M-/Fable-Kontingent, Anzeigetext „You've reached your Fable 5
/// limit" —, dann kappt `hGs()` in `VA()` auf `g_e = 200000`, und zwar VOR
/// `Esd()`. Das trifft dann jedes Modell: im diskriminierenden Gegentest wurde
/// selbst `gpt-5.6-sol` mit `CLAUDE_CODE_MAX_CONTEXT_TOKENS=900000` bei einem
/// 310k-Prompt clientseitig geblockt. Gegen dieses Limit hilft kein Stempel;
/// der Stempel adressiert ausschließlich den Metadaten-Pfad oben.
///
/// `CLAUDE_CODE_MAX_CONTEXT_TOKENS` kann keinen der beiden Pfade heilen: In
/// `Esd()` gilt sie nur für IDs OHNE `claude-`-Präfix, in `wsd()` nur zusammen
/// mit `DISABLE_COMPACT`. Deshalb blieben die Fixversuche daran wirkungslos.
enum ClaudeNativeContextAlias {
    static let memorySuffix = "[1m]"

    /// Familien-Präfixe mit belegter 1M-Fähigkeit. Bewusst konservativ: Was
    /// hier nicht steht, bleibt unangetastet (kein Stempel), damit ein
    /// unbekanntes oder nicht-1M-fähiges Modell nie ein Suffix bekommt, das
    /// der Upstream ablehnen würde. Haiku fehlt absichtlich — es ist nicht
    /// 1M-fähig. IDs dürfen Datums-/Versionsstempel tragen
    /// (`claude-fable-5-20260101`), deshalb Präfix- statt Gleichheitsvergleich.
    private static let oneMillionCapableFamilies = [
        "claude-fable-5",
        "claude-opus-5",
        "claude-opus-4-6",
        "claude-opus-4-7",
        "claude-opus-4-8",
        "claude-sonnet-5",
        "claude-sonnet-4-6",
    ]

    /// Liefert die zu stempelnde Modell-ID mit `[1m]`, oder `nil`, wenn nichts
    /// zu tun ist: kein natives Claude-Modell (GPT läuft über
    /// `ClaudeGPTModelAlias`), Suffix schon vorhanden, oder Familie ohne
    /// belegte 1M-Fähigkeit.
    static func oneMillionAlias(forTranscriptModel model: String) -> String? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.lowercased()
        guard normalized.hasPrefix("claude-") else { return nil }
        guard !normalized.contains(memorySuffix) else { return nil }
        guard oneMillionCapableFamilies.contains(where: normalized.hasPrefix) else {
            return nil
        }
        return trimmed + memorySuffix
    }
}
