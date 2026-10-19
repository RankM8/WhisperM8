import Foundation

/// Bereinigt Text, der per Bracketed Paste in eine Chat-TUI geht
/// (`chats send`, Queue, Diktat-Routing).
///
/// LR-CLI-001: Ein Prompt aus Webseite, Datei oder Tool-Ausgabe konnte die
/// Bytes `ESC[201~` enthalten. Die beendeten den Paste-Modus vorzeitig, und der
/// Rest kam als getippte Tasten an — Enter genügte für Slash-Befehle, den
/// `!`-Shell-Modus oder die Bestätigung eines Freigabe-Dialogs. Deshalb fallen
/// alle Steuerzeichen weg (C0 außer Tab und Zeilenumbruch, DEL, C1 inklusive
/// 8-Bit-CSI `0x9B`), und mit ESC jede Escape-Sequenz. Wagenrücklauf wird zu
/// Zeilenumbruch: im Paste-Block bedeuten beide dasselbe.
enum TerminalPasteSanitizer {
    static let pasteStart = "\u{1B}[200~"
    static let pasteEnd = "\u{1B}[201~"

    static func sanitize(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var scalars = String.UnicodeScalarView()
        var iterator = normalized.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            switch scalar.value {
            case 0x1B:
                skipEscapeSequence(&iterator)
            case 0x9B:
                skipCSIBody(&iterator)
            case 0x09, 0x0A:
                scalars.append(scalar)
            case 0x00...0x1F, 0x7F...0x9F:
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// Genau ein Start- und ein End-Marker um den bereinigten Text.
    static func bracketedPastePayload(_ text: String) -> String {
        pasteStart + sanitize(text) + pasteEnd
    }

    /// ESC + `[` → CSI bis zum Endbyte (0x40–0x7E); ESC + anderes → nur dieses
    /// eine Folgezeichen (z. B. `ESC 7`) entfällt mit.
    private static func skipEscapeSequence(_ iterator: inout String.UnicodeScalarView.Iterator) {
        guard let next = iterator.next() else { return }
        if next == "[" { skipCSIBody(&iterator) }
    }

    private static func skipCSIBody(_ iterator: inout String.UnicodeScalarView.Iterator) {
        while let scalar = iterator.next() {
            if (0x40...0x7E).contains(scalar.value) { return }
        }
    }
}
