import AppKit
import KeyboardShortcuts

// MARK: - Hotkey

extension KeyboardShortcuts.Name {
    /// Öffnet den Verlauf. Standard ⇧⌘C wie bei Maccy; umbelegbar in den Einstellungen.
    static let clipboardHistory = Self("clipboardHistory", default: .init(.c, modifiers: [.command, .shift]))
}

// MARK: - Tastaturbefehle im Verlaufs-Fenster

/// Reine Zuordnung Taste → Befehl, damit sie ohne AppKit-Fenster testbar ist.
enum ClipboardKeyCommand: Equatable {
    case moveUp
    case moveDown
    case paste
    case pastePlain
    case quickSelect(Int)
    case togglePin
    case delete
    /// ⌘D: nur Diktate zeigen bzw. wieder alles.
    case toggleDictationFilter
    case close

    /// `nil` heißt: die Taste gehört dem Suchfeld (Tippen, Cursor, Auswahl).
    static func resolve(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> ClipboardKeyCommand? {
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        switch keyCode {
        case 126 where flags.isEmpty: return .moveUp
        case 125 where flags.isEmpty: return .moveDown
        case 53 where flags.isEmpty: return .close
        case 36, 76:
            if flags.isEmpty { return .paste }
            if flags == .option { return .pastePlain }
            return nil
        case 51 where flags == .command: return .delete
        default: break
        }
        guard flags == .command, let characters, characters.count == 1 else { return nil }
        if characters == "p" { return .togglePin }
        if characters == "d" { return .toggleDictationFilter }
        if let digit = Int(characters), (1...9).contains(digit) { return .quickSelect(digit) }
        return nil
    }
}
