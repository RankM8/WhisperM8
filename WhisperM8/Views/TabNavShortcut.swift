import AppKit

/// Reine, testbare Tab-Wechsel-Erkennung aus KeyCode + Modifiern.
///
/// Unterstützt bewusst ZWEI Chords: `⌘⌥←/→` (Chrome-Muscle-Memory) und
/// `⌘⇧←/→` (Safari-Muscle-Memory).
///
/// Wichtig — die Modifier werden auf `[.command, .option, .control, .shift]`
/// maskiert, NICHT auf `.deviceIndependentFlagsMask`: macOS setzt auf den
/// Pfeiltasten zusätzlich `.function` UND `.numericPad`. Diese überleben die
/// deviceIndependent-Maske, weshalb ein strikter `== [.command, .option]`-
/// Vergleich für Pfeiltasten IMMER fehlschlägt (der frühere Bug: ⌘⌥←/→ hat
/// nie ausgelöst, während ⌘W als Buchstabentaste ohne diese Flags funktionierte).
enum TabNavShortcut {
    /// Richtung für den Tab-Wechsel: `-1` (vorheriger) / `+1` (nächster) /
    /// `nil` (keine passende Combo).
    static func direction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Int? {
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        guard mods == [.command, .option] || mods == [.command, .shift] else { return nil }
        switch keyCode {
        case TerminalShortcut.KeyCode.leftArrow: return -1
        case TerminalShortcut.KeyCode.rightArrow: return +1
        default: return nil
        }
    }
}
