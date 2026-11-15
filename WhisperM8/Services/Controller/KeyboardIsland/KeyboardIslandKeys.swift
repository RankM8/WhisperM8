import AppKit

/// Pure, getestete Tastenregeln der Insel per Tastatur (WM8-104, Variante B).
///
/// ⌥Tab öffnet „Wohin“ wie L2 am Controller; solange ⌥ gehalten ist, wirken
/// Tab, Pfeile, Return, Esc, Leertaste und Buchstaben in der Insel. Erkannt
/// wird über den keyCode, nicht über das Zeichen: Mit ⌥ liefert
/// `charactersIgnoringModifiers` je nach Layout etwas anderes, und Y/Z
/// tauschen QWERTZ und QWERTY (deshalb kommen sie nicht vor).
///
/// Modifier werden wie bei `TabSwitcherShortcut` auf
/// `[.command, .option, .control, .shift]` maskiert: Pfeile tragen
/// `.function`/`.numericPad`, CapsLock darf nichts ändern.
enum KeyboardIslandKeys {
    enum KeyCode {
        static let tab: UInt16 = 48
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let escape: UInt16 = 53
        static let space: UInt16 = 49
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
        /// ANSI-Lage, auf QWERTZ und QWERTY dieselbe Taste.
        static let w: UInt16 = 13
        static let r: UInt16 = 15
    }

    private static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// Insel öffnen: genau ⌥Tab. ⌥⇧Tab öffnet nicht (bleibt wie heute), ⌃⌥Tab
    /// ist der Sprung zum nächsten wartenden Chat, ⌃Tab der Kachel-Umschalter,
    /// ⌘Tab gehört dem System.
    static func opens(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == KeyCode.tab && modifiers.intersection(relevantModifiers) == [.option]
    }

    /// Was eine Taste bei offener Insel bewirkt.
    enum Action: Equatable {
        /// Markierung weiter (+1) oder zurück (−1): Tab/⇧Tab, ↓/↑.
        case step(Int)
        /// Reiter: ← „Chats“, → „Workspaces & Projekte“.
        case tab(Int)
        /// Return: sofort zum markierten Eintrag.
        case commit
        /// Esc: abbrechen. Erreicht nie das Terminal und beendet nie eine Aufnahme.
        case cancel
        /// Leertaste: hin und diktieren, während eines Diktats „stopp“.
        case dictate
        /// W: nächster wartender Chat, reihum.
        case nextWaiting
        /// R: zuletzt geschlossenen Chat wieder öffnen.
        case reopen
        /// Buchstabe der Tastenzeile (S M O B K · L N A C).
        case command(KeyboardIslandCommand)
        /// ?: Spickzettel der Schreib-Tasten.
        case cheatSheet
        /// Andere Taste bei gehaltenem ⌥: schlucken, sonst käme ein ⌥-Zeichen
        /// ins Terminal. Die Insel bleibt.
        case ignore
        /// Taste ohne ⌥: Das Loslassen ist uns entgangen (Menü-Tracking).
        /// Abbrechen und die Taste normal weiterlaufen lassen.
        case cancelAndPassThrough
    }

    /// - Parameter characters: `charactersIgnoringModifiers` (mit ⇧, ohne ⌥):
    ///   nur für „?“, das je nach Layout auf einer anderen Taste liegt.
    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String? = nil) -> Action {
        let mods = modifiers.intersection(relevantModifiers)
        // Esc gilt auch ohne ⌥: Es bricht nur ab und darf das Terminal nie
        // erreichen. Return ohne ⌥ heißt, das Loslassen ist uns entgangen
        // (etwa Mission Control mit gehaltenem ⌥): Es wechselt nicht zur alten
        // Markierung und wird wie Esc verschluckt — durchgereicht bestätigte es
        // womöglich eine offene Freigabe im Chat (Gegenlesen Paket 2).
        if keyCode == KeyCode.escape { return .cancel }
        let isReturn = keyCode == KeyCode.returnKey || keyCode == KeyCode.keypadEnter
        guard mods.contains(.option) else { return isReturn ? .cancel : .cancelAndPassThrough }
        if isReturn { return .commit }
        // Mit ⌘ oder ⌃ ist es ein anderes Kürzel (⌃⌥Tab, ⌘⌥←): nicht für uns,
        // aber auch nicht ins Terminal, solange die Insel offen ist.
        guard mods.isDisjoint(with: [.command, .control]) else { return .ignore }
        let shift = mods.contains(.shift)
        if characters == "?" { return .cheatSheet }
        switch keyCode {
        case KeyCode.tab: return .step(shift ? -1 : 1)
        case KeyCode.downArrow: return .step(1)
        case KeyCode.upArrow: return .step(-1)
        case KeyCode.leftArrow: return .tab(-1)
        case KeyCode.rightArrow: return .tab(1)
        case KeyCode.space: return .dictate
        case KeyCode.w where !shift: return .nextWaiting
        case KeyCode.r where !shift: return .reopen
        default:
            guard !shift, let command = KeyboardIslandCommand.command(keyCode: keyCode) else { return .ignore }
            return .command(command)
        }
    }

    // MARK: - Options-Menü per Tastatur

    /// Tasten im Options-Menü, das B oder K per Tastatur geöffnet hat.
    enum MenuAction: Equatable {
        case move(Int)
        /// Return, →: Eintrag wählen bzw. Unterseite öffnen.
        case activate
        /// Esc, ←: eine Ebene zurück, auf der ersten Ebene schließen.
        case back
        /// Jede andere Taste: Menü zu, die Taste läuft normal weiter.
        case closeAndPassThrough
    }

    static func menuAction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> MenuAction {
        let mods = modifiers.intersection(relevantModifiers)
        guard mods.isDisjoint(with: [.command, .control]) else { return .closeAndPassThrough }
        switch keyCode {
        case KeyCode.downArrow: return .move(1)
        case KeyCode.upArrow: return .move(-1)
        case KeyCode.tab: return .move(mods.contains(.shift) ? -1 : 1)
        case KeyCode.returnKey, KeyCode.keypadEnter, KeyCode.rightArrow: return .activate
        case KeyCode.escape, KeyCode.leftArrow: return .back
        default: return .closeAndPassThrough
        }
    }

    // MARK: - ⌥ loslassen

    enum FlagsChange: Equatable {
        /// ⌥ noch gehalten.
        case none
        /// Echtes Loslassen von ⌥: zum markierten Eintrag wechseln.
        case commit
        /// ⌥ fehlt, aber dieses Ereignis hat es nicht losgelassen: Das
        /// Loslassen ist uns entgangen. Nicht in die alte Markierung wechseln.
        case cancel
    }

    /// Modifier, deren Wechsel zählt (wie beim ⌃Tab-Umschalter, CapsLock
    /// dabei: ein CapsLock-Wechsel ist kein ⌥-Loslassen).
    private static let trackedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .capsLock]

    /// `previous`: zuletzt gesehener Modifier-Stand der offenen Insel. Ein
    /// Ereignis ändert immer nur eine Taste; Wechsel nur, wenn genau ⌥ fiel.
    static func flagsChange(previous: NSEvent.ModifierFlags, current: NSEvent.ModifierFlags) -> FlagsChange {
        let before = previous.intersection(trackedModifiers)
        let after = current.intersection(trackedModifiers)
        guard !after.contains(.option) else { return .none }
        if before.contains(.option), before.symmetricDifference(after) == .option { return .commit }
        return .cancel
    }

    // MARK: - Zeitpunkte

    /// So lange nach ⌥Tab bleibt die Insel unsichtbar: Schnell gegriffen
    /// (⌥Tab kurz) blitzt sie nicht auf, der Wechsel geht trotzdem.
    static let revealDelay: TimeInterval = 0.2
}
