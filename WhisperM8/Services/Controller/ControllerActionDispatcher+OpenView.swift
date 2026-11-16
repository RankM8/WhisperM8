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
        terminals.openViewForSending(in: sessionID) != nil
    }

    /// Kreuz (Enter), Dreieck (Leerzeichen) und L1 + Dreieck (Zeilenumbruch)
    /// im Chat: nur in den drei Ansichten, die der Controller-Leser nicht kennt.
    /// In `/config` heißt es „Enter/Space to change“.
    func unknownViewBlocksKey(_ key: ControllerChatKey, to sessionID: UUID) -> Bool {
        guard key == .enter || key == .space || key == .newline,
              let view = terminals.openViewForSending(in: sessionID) else { return false }
        return Self.viewsUnknownToTheControllerReader.contains(view)
    }
}

extension ControllerTerminalControlling {
    /// Ohne Ablesung keine Ansicht.
    func openViewForSending(in sessionID: UUID) -> String? { nil }
}
