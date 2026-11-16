import Foundation

/// Offene Ansichten vor Text und Enter (WM8-123, Befund der Prüferin am
/// 16.11.2026): In Claudes Einstellungsansicht (`/config`) wählt ein Enter
/// eine Einstellung — so wurde Auto-compact für alle Konten ausgeschaltet. In
/// der Agent-Liste startet ein Enter mit Text eine neue Hintergrund-Sitzung,
/// in der Verlaufssuche übernimmt es einen Treffer. Der Leser des Controllers
/// kennt diese drei Ansichten nicht; die Ablesung von `send` und Warteschlange
/// schon (`ComposerFieldReading.viewWithoutUsableField`).
extension ControllerActionDispatcher {
    /// Die Ansichten, die nur die Sendeprüfung kennt. Dort halten Kreuz,
    /// Dreieck und das verzögerte Enter an; in den Ansichten des
    /// Controller-Lesers (Zurückspulen, Auswahl in der Fußzeile …) wählt
    /// Kreuz dagegen gewollt aus.
    static let viewsUnknownToTheControllerReader: Set<String> = ["agentList", "config", "historySearch"]

    /// „Weiter“, Slash-Befehle, Einfügen, „Jetzt senden“: Text oder Enter
    /// gehören ins Eingabefeld. Steht irgendeine Ansicht offen, geht nichts
    /// raus. Liest den Bildschirm einmal (nur Claude).
    func openViewBlocksSending(to sessionID: UUID) -> Bool {
        terminals.composerReadingForSending(in: sessionID)?.openView != nil
    }

    /// Kreuz (Enter), Dreieck (Leerzeichen) und L1 + Dreieck (Zeilenumbruch)
    /// im Chat: nur in den drei Ansichten, die der Controller-Leser nicht kennt.
    /// In `/config` heißt es „Enter/Space to change“.
    ///
    /// In `/config` zusätzlich ◀ ▶ (Steuerkreuz, auch als Wortsprung mit L1):
    /// Ein Pfeil links schaltete dort am 16.11.2026 Auto-compact aus, und
    /// Claude schrieb es sofort in die geteilte `settings.json` (Auflage der
    /// Prüferin). ↑ ↓ und Esc bleiben frei: Damit navigiert und schließt man.
    ///
    /// In der Agent-Liste darf Kreuz bei sichtbar leerem Feld: Enter heißt dort
    /// „zurück“ („enter to return“), und ob Esc oder ◀ ebenso zurückführen, ist
    /// nicht belegt. Mit Text im Feld startete Enter eine neue Hintergrund-
    /// Sitzung; das bleibt gesperrt (Frage der Prüferin, 16.11.2026).
    func unknownViewBlocksKey(_ key: ControllerChatKey, to sessionID: UUID) -> Bool {
        let writes = key == .enter || key == .space || key == .newline
        let changesSetting = key == .left || key == .right || key == .wordLeft || key == .wordRight
        guard writes || changesSetting, let reading = terminals.composerReadingForSending(in: sessionID),
              let view = reading.openView, Self.viewsUnknownToTheControllerReader.contains(view) else { return false }
        if view == Self.agentListView, key == .enter, reading.field?.isEmpty == true { return false }
        return writes || view == Self.configView
    }

    /// Kennungen in `ComposerFieldReading.viewWithoutUsableField`.
    static let configView = "config"
    static let agentListView = "agentList"
}

extension ControllerTerminalControlling {
    /// Ohne Ablesung keine Ansicht.
    func composerReadingForSending(in sessionID: UUID) -> ComposerFieldReading? { nil }
}
