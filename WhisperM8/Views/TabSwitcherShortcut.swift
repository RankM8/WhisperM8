import AppKit

/// Reine, testbare Erkennung des Ctrl+Tab-Umschalters (Alt-Tab-artiger
/// Tab-Switcher der Agent-Chats).
///
/// Wie `TabNavShortcut` werden die Modifier auf
/// `[.command, .option, .control, .shift]` maskiert, NICHT auf
/// `.deviceIndependentFlagsMask` — macOS hängt an Sondertasten gerne
/// Zusatz-Flags an (`.function`/`.numericPad` auf Pfeilen, `.capsLock`),
/// die einen strikten Vergleich sonst immer scheitern lassen.
enum TabSwitcherShortcut {
    enum KeyCode {
        static let tab: UInt16 = 48
        static let escape: UInt16 = 53
        static let returnKey: UInt16 = 36
        // Vertikale Grid-Navigation im Karten-Switcher (↑/↓ = eine Reihe).
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
    }

    /// Richtung für den Switcher-Schritt: `+1` (Ctrl+Tab, nächster Tab) /
    /// `-1` (Ctrl+Shift+Tab, vorheriger) / `nil` (keine passende Combo).
    /// Command/Option schließen aus — ⌘Tab ist der System-App-Switcher.
    static func direction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Int? {
        guard keyCode == KeyCode.tab else { return nil }
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        if mods == [.control] { return +1 }
        if mods == [.control, .shift] { return -1 }
        return nil
    }

    /// ⌃⌥Tab: Sprung zum nächsten wartenden Chat (`NextWaitingChatResolver`).
    /// Layoutunabhängig über den keyCode — ⌃\` lag auf deutschen
    /// ISO-Tastaturen auf der `<`-Taste. Exakt Control+Option: mit Shift,
    /// Command oder ohne Option ist es nicht dieser Sprung (⌃Tab/⌃⇧Tab
    /// gehören dem Switcher, siehe `direction`, das ⌃⌥Tab ausschließt).
    static func isNextWaitingChat(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard keyCode == KeyCode.tab else { return false }
        return modifiers.intersection([.command, .option, .control, .shift]) == [.control, .option]
    }

    // MARK: - Tasten bei AKTIVEM Switcher

    /// Was ein `keyDown` bei laufendem Durchlauf bewirkt
    /// (`handleTabSwitcherKeyDown`).
    enum ActiveKeyAction: Equatable {
        /// Ctrl+Tab (+1) / Ctrl+Shift+Tab (-1).
        case step(Int)
        /// Pfeiltaste bei gehaltenem Ctrl — Auswertung je Situation (Grid
        /// und Mini-Map räumlich, Liste linear).
        case arrow(GridFocusDirection)
        /// Return: sofort committen.
        case commit
        /// Esc oder eine andere Taste MIT Ctrl: abbrechen und schlucken — ein
        /// Ctrl+C darf die laufende TUI nie erreichen, Esc würde dort die
        /// Generation abbrechen.
        case cancel
        /// Taste OHNE Ctrl (außer Esc/Return): Das Loslassen von Ctrl ist uns
        /// entgangen (z. B. während eines Kontextmenüs — lokale Monitore
        /// laufen im Menü-Tracking nicht). Abbrechen und das Event
        /// DURCHREICHEN — der Nutzer tippt längst wieder normal.
        case cancelAndPassThrough
    }

    static func activeKeyAction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> ActiveKeyAction {
        if let step = direction(keyCode: keyCode, modifiers: modifiers) { return .step(step) }
        switch keyCode {
        case KeyCode.escape: return .cancel
        case KeyCode.returnKey: return .commit
        default: break
        }
        guard modifiers.contains(.control) else { return .cancelAndPassThrough }
        if let arrow = TabSwitcherGridMarking.direction(keyCode: keyCode) { return .arrow(arrow) }
        return .cancel
    }

    // MARK: - Modifier-Änderung bei AKTIVEM Switcher

    enum FlagsChangeAction: Equatable {
        /// Ctrl noch gehalten — nichts tun.
        case none
        /// Echtes Loslassen von Ctrl: hervorgehobenen Chat übernehmen.
        case commit
        /// Ctrl fehlt, aber dieses Event hat es nicht losgelassen: Das
        /// Loslassen ist uns entgangen (Menü-Tracking). Ein späteres
        /// Shift-Drücken o. ä. darf dann NICHT ins alte Highlight committen.
        case cancel
    }

    /// Modifier, deren Wechsel zählt. `.capsLock` bewusst dabei (ein
    /// CapsLock-Toggle ist kein Ctrl-Loslassen), `.function`/`.numericPad`
    /// nicht — die hängen an Pfeil-`keyDown`s und kämen nie per
    /// `flagsChanged` zurück.
    private static let trackedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .capsLock]

    /// Entscheidung für ein `flagsChanged` bei aktivem Switcher. `previous`
    /// ist der zuletzt GESEHENE Modifier-Zustand (keyDown/flagsChanged des
    /// Durchlaufs). Commit nur, wenn Ctrl vorher gehalten war und dieses
    /// Event genau Ctrl (und nichts sonst) geändert hat — ein Event ändert
    /// immer nur eine Taste. Fehlt Ctrl, obwohl sich eine ANDERE Taste
    /// geändert hat, ging das Loslassen an uns vorbei → Abbruch.
    static func flagsChangeAction(
        previous: NSEvent.ModifierFlags,
        current: NSEvent.ModifierFlags
    ) -> FlagsChangeAction {
        let before = previous.intersection(trackedModifiers)
        let after = current.intersection(trackedModifiers)
        guard !after.contains(.control) else { return .none }
        if before.contains(.control), before.symmetricDifference(after) == .control {
            return .commit
        }
        return .cancel
    }
}
