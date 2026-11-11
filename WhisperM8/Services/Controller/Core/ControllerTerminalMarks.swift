import Foundation

/// Was die Controller-Steuerung je Chat-Terminal festhält, damit Kreuz, Kreis
/// und das Steuerkreuz nur dort wirken, wo sie nichts anrichten. Pur und ohne
/// Uhr; gehalten vom `AgentTerminalController` (ein Wert je Chat, er lebt so
/// lange wie das Terminal).
struct ControllerTerminalMarks: Equatable, Sendable {
    /// Höchstdauer einer Auswahlliste ab dem Öffnen, ohne Verlängerung: Wer
    /// länger braucht, hat sie meist anders geschlossen (Maus, anderes
    /// Programm) — dann soll das Steuerkreuz wieder navigieren.
    static let choiceListTimeout: TimeInterval = 120

    /// Enter vom Controller, auch in einer Rückfrage.
    var lastEnterAt: Date?
    var lastEscapeAt: Date?
    /// Zuletzt per Controller ins Eingabefeld geschrieben oder daraus gelöscht
    /// (Rücktaste, Leerzeichen, Wort löschen, Text oder Diktat ohne Senden,
    /// bei Codex auch Pfeile).
    var lastDraftInputAt: Date?
    /// Enter (ohne Shift/Option) auf der Tastatur des Nutzers.
    var lastKeyboardSubmitAt: Date?
    /// „Auswahl offen“: gesetzt, wenn das Controller-Menü einen Befehl
    /// geschickt hat, der eine Liste öffnet. `nil` = keine Liste.
    private(set) var choiceListOpenedAt: Date?

    /// Zuletzt abgeschickt, auf jedem Weg: Enter vom Controller oder von der
    /// Tastatur und jeder programmatische Versand (`chats send`, Diktat mit
    /// Senden, Menü-Befehle — `programmatic` kommt vom Entwurfs-Tracker).
    func lastSubmitAt(programmatic: Date?) -> Date? {
        [lastEnterAt, lastKeyboardSubmitAt, programmatic].compactMap { $0 }.max()
    }

    func isChoiceListOpen(at now: Date) -> Bool {
        guard let opened = choiceListOpenedAt else { return false }
        return now.timeIntervalSince(opened) < Self.choiceListTimeout
    }

    mutating func choiceListOpened(at now: Date) {
        choiceListOpenedAt = now
    }

    mutating func choiceListClosed() {
        choiceListOpenedAt = nil
    }

    /// Taste auf der Tastatur des Nutzers: Enter zählt als Absenden. Jede
    /// Taste außer Pfeilen und Leerzeichen schließt eine Liste — auch die
    /// Rücktaste, die ein „/“ aus dem Menü wieder löscht (danach wäre das Feld
    /// leer, und links schickte Claude in den Hintergrund).
    mutating func recordKeyboard(submit: Bool, keepsChoiceList: Bool, at now: Date) {
        if submit { lastKeyboardSubmitAt = now }
        if !keepsChoiceList { choiceListClosed() }
    }

    /// Kreuz darf bei arbeitendem Chat Enter schicken, wenn per Controller
    /// kürzlich etwas eingegeben und seitdem nichts abgeschickt wurde
    /// (Review nach Runde 3, Befund 5: auch ein Enter in einer Rückfrage oder
    /// auf der Tastatur hebt die Eingabe auf).
    static func hasFreshDraftInput(
        draftAt: Date?, lastSubmitAt: Date?, window: TimeInterval, now: Date
    ) -> Bool {
        guard let draftAt, now.timeIntervalSince(draftAt) < window else { return false }
        guard let lastSubmitAt else { return true }
        return draftAt > lastSubmitAt
    }
}
