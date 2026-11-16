import Foundation

/// Wann geht das Enter nach einem Einfüge-Block raus? (WM8-119)
///
/// Vorfall 16.11.2026: Zwei lange Meldungen an den Supervisor blieben im
/// Eingabefeld stehen (`queue_stuck_in_field`), eine dritte am Vormittag. Alle
/// drei enthielten Pfade zu PNG-Dateien (Snapshots). Claude Code liest
/// eingefügte Bildpfade erst ein und macht daraus Anhänge („[Image #1]“); so
/// lange steht vom Einfügen noch nichts im Feld. Ein Enter in dieser Zeit
/// merkt sich Claude zwar, verwirft es aber, wenn das Einlesen fertig ist
/// (Claude Code 2.1.325: Nach dem Einlesen setzt es den Merker zurück, ohne
/// das Enter nachzuholen; bei reinem Text holt es das Enter nach). Unser Enter
/// kam fest nach 80 ms und verlor das Rennen, sobald das Einlesen länger
/// dauerte. Meldungen ohne Bildpfad gingen auch mit über 5.000 Zeichen durch.
///
/// Deshalb wartet das Enter bei einem Claude-Chat, der beim Einfügen ruhte, bis
/// das Feld den Text zeigt: einzeilig, Cursor am Anfang, kein Text heißt „noch
/// nicht angekommen“. Reiner Text steht nach 80 ms längst da; dann geht das
/// Enter wie bisher sofort. Pur; die Ablesung liefert der Aufrufer.
enum DelayedEnterLanding {
    /// Erster Versuch, wie bisher.
    static let firstDelaySeconds: TimeInterval = 0.08
    /// Danach so oft nachsehen.
    static let pollSeconds: TimeInterval = 0.1
    /// Längstens so lange warten. Danach geht das Enter wie früher, auch wenn
    /// der Text noch nicht im Feld steht; bleibt er dann stehen, meldet es das
    /// Nachsehen nach dem Enter (`PromptSubmitCheck`).
    static let maxWaitSeconds: TimeInterval = 3

    enum Step: Equatable {
        /// Enter jetzt (nach der Freigabe-Prüfung `DelayedEnterGuard`).
        case send
        /// Text noch nicht im Feld: gleich noch einmal nachsehen.
        case wait
        /// Während des Wartens hat jemand ins Feld geschrieben, es abgeschickt
        /// oder geleert. Kein Enter: Es schickte fremden Text mit ab.
        case skip
    }

    /// - Parameters:
    ///   - field: Eingabefeld am Bildschirm, `nil` = nicht ablesbar (dann wie bisher).
    ///   - elapsed: Zeit seit dem Einfügen.
    ///   - waited: Es gab schon einen Versuch, der gewartet hat.
    ///   - touched: Seit dem Einfügen wurde getippt, eingefügt, abgeschickt oder
    ///     geleert (Entwurfs-Tracker).
    static func step(profile: TerminalKeyboardProfile, statusAtPaste: AgentSessionRuntimeStatus?,
                     field: ControllerPromptField?, elapsed: TimeInterval,
                     waited: Bool, touched: Bool) -> Step {
        // Nur bei Claude im Ruhezustand: Codex' Feld liest die App nicht sicher,
        // und in einer Rückfrage gibt es kein Eingabefeld.
        guard profile == .claudeCodeChat, statusAtPaste == .idle else { return .send }
        if waited, touched { return .skip }
        guard let field, notLandedYet(field) else { return .send }
        return elapsed < maxWaitSeconds ? .wait : .send
    }

    /// Wartet gerade ein Enter auf seinen Text im Feld (WM8-119)? Dann gilt das
    /// Feld für `send` und die Warteschlange nicht als frei: Ein zweiter Text
    /// verschmölze mit dem ersten zu einer Meldung. Ein Eintrag, der älter ist
    /// als die Frist plus Luft, zählt nicht mehr (etwa ein geschlossener Tab,
    /// dessen Versuch nie lief); sonst bliebe der Chat gesperrt.
    static func enterPending(since: Date?, now: Date = Date()) -> Bool {
        guard let since else { return false }
        return now.timeIntervalSince(since) < maxWaitSeconds + 2
    }

    static let enterPendingMessage = "Gerade wird ein anderer Auftrag zugestellt: Sein Enter wartet, bis der "
        + "Text im Feld steht (höchstens 3 s). Vorgemerkt geht dieser hier danach raus (`enqueue`)."

    /// Das Feld sieht aus wie vor dem Einfügen: eine Zeile, Cursor ganz am
    /// Anfang, kein Text (ein grauer Vorschlag zählt nicht). Steht der Cursor
    /// nicht im Feld, ist das unklar; dann nicht warten.
    static func notLandedYet(_ field: ControllerPromptField) -> Bool {
        field.isEmpty && field.rows == 1 && field.cursorRow == 0 && field.cursorAtStart
    }
}
