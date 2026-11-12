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
    /// Leerzeichen (Dreieck am Controller).
    case space
    /// Wort zurück löschen: Ctrl+W. Belegt in Claude Code („Delete back to
    /// previous whitespace“, interactive mode) und Codex (Standard für
    /// `delete_backward_word`, `codex-rs/tui/src/keymap.rs`); in zsh und bash
    /// `backward-kill-word`. Bewusst nicht Meta+Rücktaste (ESC DEL): Ein
    /// einzelnes ESC bricht einen arbeitenden Chat ab.
    case deleteWord
    /// Zeile bis zum Cursor löschen: Ctrl+U. Claude Code: „Delete from cursor to
    /// line start … Repeat to clear across lines in multiline input“; Codex:
    /// `kill_line_start`, am Zeilenanfang wird der Umbruch davor entfernt.
    case killLineStart
    /// Ans Zeilenende: Ctrl+E (Claude Code und Codex, „move line end“).
    case lineEnd
    /// Zeilenumbruch ohne Senden: Ctrl+J, also LF (0x0A). Claude Code
    /// (interactive mode, „Multiline input“): „Control sequence `Ctrl+J`:
    /// works in any terminal without configuration“. Codex: Standard von
    /// `editor.insert_newline` in `codex-rs/tui/src/keymap.rs` ist
    /// `ctrl-j` (neben `ctrl-m`, Shift/Alt+Enter); `composer.submit` liegt
    /// nur auf Enter, und crossterm liest 0x0A im Raw-Modus als Ctrl+J. Nicht
    /// Shift+Enter: Ohne Kitty-Protokoll kommt das im PTY als CR an und würde
    /// senden.
    case newline

    /// Absicherung des Controller-Wegs (`AgentTerminalController.sendKey`);
    /// die Tastatur des Nutzers läuft nicht hier durch. Pfeile immer: Das
    /// Steuerkreuz ist im Chat die Pfeiltaste (seit 12.11.2026; vorher nur in
    /// Rückfragen, offenen Listen und Codex, was Subagenten- und
    /// Workflow-Ansichten unerreichbar machte). Tab und Shift+Tab nie in einer
    /// Rückfrage: Shift+Tab heißt in Claudes Freigabe-Dialog „alle Änderungen
    /// erlauben“. Schreibtasten (Leerzeichen, Wort löschen, Leeren) nur bei
    /// Claude und Codex: In einer Shell läuft oft nano, vim oder emacs, dort
    /// bedeuten Ctrl+U, Ctrl+W und Ctrl+E etwas anderes.
    static func controllerAllows(
        _ key: TerminalControlKey,
        status: AgentSessionRuntimeStatus?,
        profile: TerminalKeyboardProfile,
        choiceListOpen: Bool
    ) -> Bool {
        let isAgentChat = profile == .claudeCodeChat || profile == .codexChat
        switch key {
        // Pfeile immer (Entscheidung 12.11.2026): Das Steuerkreuz ist im Chat
        // die Pfeiltaste, auch in Subagenten- und Workflow-Ansichten.
        case .up, .down, .left, .right:
            return true
        case .tab, .backTab: return status != .awaitingInput
        case .enter, .escape, .backspace: return true
        case .space, .deleteWord: return isAgentChat
        // Leeren nie in einer Rückfrage: Dort wählt man aus, das Eingabefeld
        // ist nicht gemeint.
        case .killLineStart, .lineEnd, .newline: return isAgentChat && status != .awaitingInput
        }
    }

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
        case .space: return [0x20]
        case .deleteWord: return [0x17]                       // Ctrl+W
        case .killLineStart: return [0x15]                    // Ctrl+U
        case .lineEnd: return [0x05]                          // Ctrl+E
        case .newline: return [0x0A]                          // Ctrl+J (LF)
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
        case .space: return 49
        case .deleteWord: return 13                           // W
        case .killLineStart: return 32                        // U
        case .lineEnd: return 14                              // E
        // Für den Entwurfs-Tracker wie Shift+Return: ein Umbruch im Entwurf.
        case .newline: return 36
        }
    }

    var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .backTab, .newline: return .shift
        case .deleteWord, .killLineStart, .lineEnd: return .control
        default: return []
        }
    }

    /// Ganze Eingabe leeren (R3 halten): einmal ans Zeilenende, dann Ctrl+U in
    /// Stößen. Jedes Ctrl+U löscht eine Zeile bis zum Anfang oder, am
    /// Zeilenanfang, den Umbruch davor — zwei je Zeile. 8 × 16 = 128 reichen
    /// für 64 Zeilen; mehr hat ein diktierter oder getippter Entwurf kaum.
    /// Überzählige Drücke im leeren Feld tun nichts (in Claudes Shell-Modus
    /// verlassen sie ihn, wie Rücktaste im leeren Feld). Text unterhalb einer
    /// Zeile, in die der Cursor bewegt wurde, bleibt stehen — per Controller
    /// steht der Cursor nach Tippen und Diktat immer am Ende.
    /// Darf R3 halten die Eingabe leeren? Bei Claude und Codex wie die
    /// Schreibtasten (nicht in einer Rückfrage). In einer Shell nur an der
    /// Eingabezeile, also im normalen Puffer: Vollbild-Programme wie nano
    /// oder vim laufen im Alternate-Puffer, dort hieße Ctrl+U etwas
    /// anderes. An der Zeile von zsh, bash und jeder readline-Eingabe leert
    /// Ctrl+E + Ctrl+U die Zeile — sonst bliebe nach einem `chats send` der
    /// Entwurfs-Verdacht für immer stehen (E2E-Befund 12.11.2026).
    static func controllerMayClearInput(
        status: AgentSessionRuntimeStatus?,
        profile: TerminalKeyboardProfile,
        alternateBuffer: Bool,
        choiceListOpen: Bool
    ) -> Bool {
        if profile == .plainShell { return !alternateBuffer }
        return controllerAllows(.killLineStart, status: status, profile: profile, choiceListOpen: choiceListOpen)
    }

    static let clearInputBursts: [[TerminalControlKey]] =
        [[.lineEnd] + Array(repeating: .killLineStart, count: 16)]
        + Array(repeating: Array(repeating: .killLineStart, count: 16), count: 7)

}

/// Scroll-Schritte für den Verlauf eines Terminals, unabhängig vom Puffer.
enum TerminalScrollStep {
    /// SGR-Mausrad-Sequenz für TUIs im Alternate-Puffer (wie der
    /// `TerminalScrollGuard` sie für das Trackpad baut): 64 = hoch, 65 = runter.
    static func wheelSequence(up: Bool) -> String {
        "\u{1b}[<\(up ? 64 : 65);1;1M"
    }
}
