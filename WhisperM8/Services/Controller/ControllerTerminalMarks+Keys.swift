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
    /// Leerzeichen bewegen sich darin; verlängert wird die Liste nicht.
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
            // Codex meldet keine Rückfragen: Wer per Steuerkreuz in einer
            // Freigabe wählt, darf sie danach mit Kreuz bestätigen, auch wenn
            // der Chat als „arbeitet“ gilt.
            if isCodex { recordDraftInput(submitted: false, at: now) }
        case .space:
            // In `/config` schaltet Leerzeichen den Eintrag um; die Liste bleibt.
            recordDraftInput(submitted: false, at: now)
        case .backspace, .deleteWord:
            choiceListClosed()
            recordDraftInput(submitted: false, at: now)
        case .tab, .backTab, .killLineStart, .lineEnd:
            choiceListClosed()
        }
    }

    /// Taste der echten Tastatur an das Terminal: Return ohne Shift/Option ist
    /// ein Absenden; jede Taste außer Pfeilen und Leerzeichen (ohne Cmd/Ctrl)
    /// schließt eine Auswahl.
    mutating func recordKeyboard(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, at now: Date) {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        let isReturn = keyCode == 36 || keyCode == 76
        let movesInList = Self.listKeyCodes.contains(keyCode)
            && !flags.contains(.command) && !flags.contains(.control)
        recordKeyboard(
            submit: isReturn && !flags.contains(.shift) && !flags.contains(.option),
            keepsChoiceList: movesInList,
            at: now)
    }

    /// Pfeile (123–126) und Leerzeichen (49): bewegen bzw. schalten in einer Liste.
    private static let listKeyCodes: Set<UInt16> = [49, 123, 124, 125, 126]

    /// Gilt die Auswahl beim Lesen noch? Bei Claude nur, solange der Chat
    /// ruht: Arbeitet er (auch ein Turn, den Claude selbst beginnt) oder fragt
    /// er, ist die Liste zu, und Pfeile oder Kreuz gingen sonst in einen
    /// arbeitenden Chat — Kreuz bestätigte in der Lücke vor „wartet“ eine
    /// Freigabe. Ein ungültiger Merker wird dabei gelöscht, damit er nach der
    /// Rückkehr zu „ruht“ nicht wieder auflebt. Codex meldet keine Rückfragen;
    /// dort bleibt der Merker an die Zeit gebunden.
    mutating func checkedChoiceListOpen(at now: Date, status: AgentSessionRuntimeStatus?, isClaude: Bool) -> Bool {
        guard isChoiceListOpen(at: now) else { return false }
        if isClaude, status != .idle {
            choiceListClosed()
            return false
        }
        return true
    }
}
