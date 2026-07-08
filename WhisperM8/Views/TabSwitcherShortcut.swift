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
}
