import Foundation

/// Eingabefeld für die Sendeprüfung (WM8-123): bei Claude vom lebendigen
/// Bildschirm gelesen, auch wenn die Ansicht hochgescrollt ist. Steht dort
/// Text, sperrt er. Ein leeres Feld gibt nur frei, wenn die Ansicht unten
/// steht (`fieldForRelease`); hochgescrollt lockert nichts.
struct ComposerFieldReading: Equatable {
    /// `nil` = kein Feld erkannt (Dialog, offene Ansicht, Codex, nicht ablesbar):
    /// Dann entscheidet die Schätzung des Trackers.
    var field: ControllerPromptField?
    var atBottom: Bool
    /// Eine Ansicht von Claude statt (oder unter) dem Feld: Transkript,
    /// `/tasks`, `/workflows`, Zurückspulen, Auswahl in der Fußzeile,
    /// Agent-Liste, `/config`, Verlaufssuche. Ein Enter träfe dort die
    /// Ansicht, nicht das Feld.
    var openView: String? = nil

    static let unreadable = ComposerFieldReading(field: nil, atBottom: false)

    /// Nur unten darf ein sichtbar leeres Feld die Schätzung überstimmen.
    var fieldForRelease: ControllerPromptField? { atBottom ? field : nil }

    /// Ansichten, die der Controller-Leser nicht kennt, in denen das Enter einer
    /// Zustellung aber etwas auslöste (WM8-123). Abgelesen an Claude Code
    /// 2.1.325 am 16.11.2026, erkannt an der Fußzeile:
    /// - Agent-Liste (← im leeren Feld): unten ein eigenes Feld „describe a task
    ///   for a new session“, das der Leser für ein leeres Eingabefeld hält; das
    ///   Enter startete eine neue Hintergrund-Sitzung mit der Meldung. Fußzeile
    ///   „enter to return · space to reply · ctrl+x to remove“.
    /// - `/config`: kein Feld unten; das Enter wählte eine Einstellung. Fußzeile
    ///   „Type to filter · Enter/↓ to select · ↑ to tabs · Esc to clear“ bzw.
    ///   „Enter/Space to change · / to search · Esc to close“.
    /// - Verlaufssuche (Ctrl+R): das Feld zeigt einen Treffer, Fußzeile
    ///   „search prompts:“.
    ///
    /// Gesucht wird nur in der Fußzeile: mit Eingabefeld (Agent-Liste,
    /// Verlaufssuche) in den Zeilen darunter, ohne Feld (`/config`) in den
    /// untersten zwei nicht leeren Zeilen. Zitiert ein Chat diese Wortlaute in
    /// seiner Ausgabe über dem Feld, ist das keine Ansicht; sonst stünde seine
    /// Warteschlange still, bis jemand hineinschreibt (Prüferin zu WM8-123).
    /// Abgeblendet sind die Fußzeilen nicht (Claude färbt sie grau), deshalb
    /// zählt die Lage, nicht die Schrift.
    /// Kosten: ein paar Textvergleiche über die ohnehin gelesenen 16 Zeilen.
    static func viewWithoutUsableField(_ lines: [String]) -> String? {
        let footer: [String]
        if let box = ControllerScreenReading.promptBox(in: lines) {
            footer = Array(lines[(box.lower + 1)...])
        } else {
            footer = Array(lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(2))
        }
        let text = footer.map { $0.lowercased() }.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if text.contains("space to reply"), text.contains("ctrl+x to remove") || text.contains("enter to return") {
            return "agentList"
        }
        if text.contains("enter/space to change") && text.contains("esc to close")
            || text.contains("↑ to tabs") && text.contains("esc to clear") {
            return "config"
        }
        if text.contains("search prompts:") { return "historySearch" }
        return nil
    }
}

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
