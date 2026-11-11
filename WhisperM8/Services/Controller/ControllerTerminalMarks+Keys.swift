import AppKit

// Welche Taste welchen Merker der Controller-Schutzregeln setzt. Getrennt vom
// puren Kern (`ControllerTerminalMarks`, nur Foundation), weil hier die
// Terminal-Tasten und Tastatur-Ereignisse vorkommen.

extension ControllerTerminalMarks {
    /// Controller hat etwas ins Eingabefeld geschrieben oder daraus gelöscht;
    /// mit `submitted` ging es gleich ab.
    mutating func recordDraftInput(submitted: Bool, at now: Date) {
        lastDraftInputAt = submitted ? nil : now
    }

    /// Taste vom Controller, nachdem die Absicherung sie durchgelassen hat.
    /// Enter zählt als Absenden (auch in einer Rückfrage: Danach hält eine
    /// ältere Eingabe Kreuz nicht mehr scharf) und schließt eine Auswahl;
    /// Escape und alles, was das Feld ändert, schließen sie ebenso. Pfeile und
    /// Leerzeichen bewegen sich darin und halten sie offen.
    mutating func recordControllerKey(
        _ key: TerminalControlKey, status: AgentSessionRuntimeStatus?, isCodex: Bool, at now: Date
    ) {
        switch key {
        case .enter:
            lastEnterAt = now
            choiceListClosed()
            if status != .awaitingInput { recordDraftInput(submitted: true, at: now) }
        case .escape:
            lastEscapeAt = now
            choiceListClosed()
        case .up, .down, .left, .right:
            choiceListUsed(at: now)
            // Codex meldet keine Rückfragen: Wer per Steuerkreuz in einer
            // Freigabe wählt, darf sie danach mit Kreuz bestätigen, auch wenn
            // der Chat als „arbeitet“ gilt.
            if isCodex { recordDraftInput(submitted: false, at: now) }
        case .space:
            // In `/config` schaltet Leerzeichen den Eintrag um.
            choiceListUsed(at: now)
            recordDraftInput(submitted: false, at: now)
        case .backspace, .deleteWord:
            choiceListClosed()
            recordDraftInput(submitted: false, at: now)
        case .tab, .backTab, .killLineStart, .lineEnd:
            choiceListClosed()
        }
    }

    /// Taste der echten Tastatur an das Terminal: Return ohne Shift/Option ist
    /// ein Absenden, Escape schließt eine Auswahl.
    mutating func recordKeyboard(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, at now: Date) {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        let isReturn = keyCode == 36 || keyCode == 76
        recordKeyboard(
            submit: isReturn && !flags.contains(.shift) && !flags.contains(.option),
            escape: keyCode == 53 && flags.isEmpty,
            at: now)
    }
}
