import Foundation

/// Wurde ein eingefügter Prompt wirklich abgeschickt (WM8-100)?
///
/// Vorfall 14.11.2026: Nach `resume` stand der Auftrag im Eingabefeld, das
/// Enter war verloren, `send` meldete trotzdem „delivered“. Wer daraufhin
/// noch einmal sendete, hängte den Text ein zweites Mal an. Deshalb sieht die
/// App nach dem Enter kurz nach: Ein Turn beginnt, oder das Feld ist leer —
/// dann ist der Text raus. Steht er nach der Frist noch im Feld, sagt sie das.
///
/// Pur; die Ablesung (Status, Feld am Bildschirm) liefert der Aufrufer.
/// Nur für Claude-Chats, die beim Einfügen ruhten: Bei einer offenen
/// Rückfrage gibt es kein Eingabefeld, und Codex' Feld liest die App nicht
/// sicher genug ab.
enum PromptSubmitCheck {
    enum Verdict: String, Equatable {
        /// Der Chat arbeitet (oder fragt schon zurück).
        case started
        /// Das Feld ist leer, der Text ist raus (etwa ein Slash-Befehl, der
        /// keinen Turn startet).
        case submitted
        /// Der Text steht nach der Frist noch im Eingabefeld.
        case stuckInField
        /// Nicht ablesbar (Ansicht hochgescrollt); wie früher „zugestellt“.
        case unknown
    }

    /// So lange wird nachgesehen.
    static let windowSeconds: TimeInterval = 4
    /// Ein leeres Feld zählt erst danach: Davor hat die TUI den Paste unter
    /// Umständen noch gar nicht gezeichnet.
    static let emptyFieldAfterSeconds: TimeInterval = 0.8
    static let pollSeconds: TimeInterval = 0.2

    /// `nil` = weiter nachsehen.
    static func evaluate(status: AgentSessionRuntimeStatus?, field: ControllerPromptField?,
                         elapsed: TimeInterval) -> Verdict? {
        if status == .working || status == .awaitingInput { return .started }
        if let field, field.isEmpty, elapsed >= emptyFieldAfterSeconds { return .submitted }
        guard elapsed >= windowSeconds else { return nil }
        return field?.hasText == true ? .stuckInField : .unknown
    }

    /// Wartet auf ein Urteil. `probe` liest Status und Feld (auf dem
    /// MainActor), `sleep` und `clock` sind für Tests austauschbar.
    static func waitForVerdict(
        probe: @MainActor () -> (AgentSessionRuntimeStatus?, ControllerPromptField?),
        sleep: (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        clock: () -> Date = Date.init
    ) async -> Verdict {
        let start = clock()
        while true {
            await sleep(pollSeconds)
            let (status, field) = await MainActor.run { probe() }
            if let verdict = evaluate(status: status, field: field, elapsed: clock().timeIntervalSince(start)) {
                return verdict
            }
        }
    }

    /// Nachsehen lohnt nur bei einem ruhenden Claude-Chat, und nur mit Enter.
    static func applies(submit: Bool, profile: TerminalKeyboardProfile, statusAtSend: AgentSessionRuntimeStatus?) -> Bool {
        submit && profile == .claudeCodeChat && statusAtSend == .idle
    }

    /// Steht sichtbar Text im Claude-Eingabefeld, der nicht ohnehin vor dem
    /// Einfügen geleert wird (Rückleger nach einem Abbruch)?
    static func visibleDraft(field: ControllerPromptField?, profile: TerminalKeyboardProfile,
                             clearsBeforeSubmit: Bool) -> Bool {
        profile == .claudeCodeChat && !clearsBeforeSubmit && field?.hasText == true
    }

    /// Das Claude-Eingabefeld ist am Bildschirm sichtbar leer (WM8-64). Das
    /// schlägt die Tasten-Schätzung: Sie hält ein Feld nach getippten und
    /// wieder gelöschten Zeichen weiter für einen Entwurf, `send` merkte dann
    /// vor und die Warteschlange stellte einem ruhenden Chat nie zu (15.11.,
    /// Chat mit laufendem Hintergrund-Befehl). Nicht ablesbar heißt `false`,
    /// dann gilt die Schätzung wie bisher.
    ///
    /// Streng, weil es den Sendeweg lockert (Uli zu WM8-64): Eine Fehl-Ablesung
    /// Richtung „leer“ würde zu einem Senden mit Enter. Leer heißt deshalb:
    /// hinter dem „❯“ steht gar nichts, auch nichts Abgeblendetes (ein grauer
    /// Vorschlag oder ein abgeblendeter Platzhalter für eingefügten Text, auf
    /// dessen Anfang der Nutzer den Cursor gesetzt hat), das Feld hat eine
    /// Zeile, und der Cursor steht in ihr ganz am Anfang. Der Cursor bestätigt,
    /// dass es das echte Feld ist und nicht zwei Linien aus einer Tool-Ausgabe
    /// weiter oben. Steht ein grauer Vorschlag da, entscheidet die Schätzung.
    static func fieldVisiblyEmpty(field: ControllerPromptField?, profile: TerminalKeyboardProfile) -> Bool {
        guard profile == .claudeCodeChat, let field else { return false }
        return field.isBlank && field.isEmpty && field.rows == 1 && field.cursorRow == 0 && field.cursorAtStart
    }

    static let stuckMessage = "Der Text steht im Eingabefeld des Chats, wurde aber nicht abgeschickt. "
        + "Nicht noch einmal senden, sonst kommt er doppelt: `whisperm8 chats submit <ref>` schickt ihn ab, "
        + "`whisperm8 chats interrupt <ref> --clear-input --force` leert das Feld."

    static let visibleDraftMessage = "Im Eingabefeld des Ziel-Chats steht schon Text. Der Prompt würde angehängt "
        + "und beides zusammen abgeschickt. Steht dort ein liegengebliebener Auftrag: `whisperm8 chats submit <ref>` "
        + "schickt ihn ab, `whisperm8 chats interrupt <ref> --clear-input --force` leert das Feld. Sonst "
        + "`whisperm8 chats enqueue <ref> \"…\"` oder bewusst `--force`."
}
