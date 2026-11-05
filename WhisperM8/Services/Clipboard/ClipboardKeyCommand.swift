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
    /// ⌘Y: Bild groß ansehen (wie die Übersicht im Finder) und zurück.
    case toggleZoom
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
        if characters == "y" { return .toggleZoom }
        if let digit = Int(characters), (1...9).contains(digit) { return .quickSelect(digit) }
        return nil
    }

    /// Tasten in der großen Bildansicht. `nil` heißt: Taste wird geschluckt,
    /// nichts geht ans Suchfeld. Leertaste schließt wie im Finder; der
    /// Diktat-Filter (⌘D) ist gesperrt, weil er die Liste unter dem Bild tauscht.
    static func resolveWhileZoomed(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> ClipboardKeyCommand? {
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        if keyCode == 49, flags.isEmpty { return .toggleZoom }
        guard let command = resolve(keyCode: keyCode, characters: characters, modifiers: modifiers) else { return nil }
        return command == .toggleDictationFilter ? nil : command
    }
}

