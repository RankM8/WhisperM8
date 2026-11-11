import AppKit

/// Einzelne Tasten, die die App selbst an eine laufende TUI schicken darf —
/// für die Bedienung ohne Tastatur (Controller). Bewusst eine feste, kurze
/// Liste und kein allgemeines Send-Keys: Rückfragen beantworten (Pfeile,
/// Enter, Escape), den Modus wechseln (Shift+Tab) und Zeichen löschen
/// (Rücktaste), mehr nicht.
///
/// Über den Control-Socket ist das nicht erreichbar; `chats interrupt` und
/// `chats send` bleiben die einzigen Wege von außen.
enum TerminalControlKey: String, CaseIterable, Sendable {
    case enter, escape, up, down, left, right, tab, backTab, backspace

    /// Bytes für das PTY. Pfeile richten sich nach dem Cursor-Modus des
    /// Terminals (DECCKM): normal `ESC [ A`, im Application-Modus `ESC O A`.
    ///
    /// Auch bei aktivem Kitty-Tastaturprotokoll bleiben das gültige Eingaben:
    /// Pfeile, Tab und Shift+Tab behalten dort ihre klassische Form, und rohes
    /// ESC und CR versteht jede TUI, die wir hosten (`chats interrupt` und
    /// `chats send` schicken sie seit jeher so).
    func bytes(applicationCursor: Bool) -> [UInt8] {
        let introducer: UInt8 = applicationCursor ? 0x4F : 0x5B   // "O" bzw. "["
        switch self {
        case .enter: return [0x0D]
        case .escape: return [0x1B]
        case .up: return [0x1B, introducer, 0x41]
        case .down: return [0x1B, introducer, 0x42]
        case .right: return [0x1B, introducer, 0x43]
        case .left: return [0x1B, introducer, 0x44]
        case .tab: return [0x09]
        case .backTab: return [0x1B, 0x5B, 0x5A]              // ESC [ Z
        case .backspace: return [0x7F]                        // DEL, wie die Rücktaste
        }
    }

    /// Virtueller Tastencode der entsprechenden Taste. Damit bekommt der
    /// Entwurfs-Tracker dieselbe Meldung wie bei einem echten Tastendruck.
    var keyCode: UInt16 {
        switch self {
        case .enter: return 36
        case .escape: return 53
        case .up: return 126
        case .down: return 125
        case .left: return 123
        case .right: return 124
        case .tab, .backTab: return 48
        case .backspace: return 51
        }
    }

    var modifiers: NSEvent.ModifierFlags {
        self == .backTab ? .shift : []
    }
}

/// Scroll-Schritte für den Verlauf eines Terminals, unabhängig vom Puffer.
enum TerminalScrollStep {
    /// SGR-Mausrad-Sequenz für TUIs im Alternate-Puffer (wie der
    /// `TerminalScrollGuard` sie für das Trackpad baut): 64 = hoch, 65 = runter.
    static func wheelSequence(up: Bool) -> String {
        "\u{1b}[<\(up ? 64 : 65);1;1M"
    }
}
