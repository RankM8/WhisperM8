import Foundation
import SwiftTerm

// Ablesen des unteren Bildschirmrands für den Controller (Runde 5, R2):
// offene Claude-Ansicht und Eingabefeld. Nur im Ereignis-Pfad einer
// Controller-Eingabe, nie in einem Body und nie je Abtastwert.

extension AgentTerminalController {
    /// Unterer Rand des lebendigen Bildschirms, nur bei Claude und Codex und
    /// nur, wenn die Ansicht ganz unten steht (sonst zeigt `getLine` den
    /// hochgescrollten Ausschnitt). `nil` heißt: nicht ablesbar.
    func controllerScreenSnapshot() -> ControllerScreenSnapshot? {
        let profile = command.keyboardProfile
        guard isRunning, profile == .claudeCodeChat || profile == .codexChat else { return nil }
        let swiftTerm = terminal.getTerminal()
        let atBottom = swiftTerm.isCurrentBufferAlternate || !terminal.canScroll || terminal.scrollPosition >= 1
        guard atBottom else { return nil }
        PerformanceCounters.shared.count(.controllerScreenRead)
        let capture = ControllerScreenCapture.bottomLines(of: swiftTerm)
        return ControllerScreenReading.read(
            lines: capture.lines, cursor: capture.cursor, detectViews: profile == .claudeCodeChat)
    }
}

/// Liest die unteren Zeilen eines SwiftTerm-Terminals in den drei Fassungen
/// von `ControllerScreenLine`. Getrennt vom Controller, damit Tests echte
/// ANSI-Folgen durch einen `Terminal` schicken können.
enum ControllerScreenCapture {
    static func bottomLines(of terminal: Terminal) -> (lines: [ControllerScreenLine], cursor: (row: Int, col: Int)?) {
        let count = min(ControllerScreenReading.lineCount, terminal.rows)
        let firstRow = terminal.rows - count
        var lines: [ControllerScreenLine] = []
        lines.reserveCapacity(count)
        for row in firstRow..<terminal.rows {
            guard let line = terminal.getLine(row: row) else {
                lines.append(ControllerScreenLine(full: "", plain: "", dim: ""))
                continue
            }
            // Alle drei Fassungen über dieselbe Zellenfolge: gleich viele Zeichen.
            func render(_ keep: @escaping (CharacterStyle) -> Bool) -> String {
                line.translateToString(trimRight: false, skipNullCellsFollowingWide: true) { cell in
                    let character = cell.getCharacter()
                    // Leere Zellen liefern NUL.
                    return character == "\u{0}" || !keep(cell.attribute.style) ? " " : character
                }
            }
            func isFaint(_ style: CharacterStyle) -> Bool { style.contains(.dim) || style.contains(.invisible) }
            lines.append(ControllerScreenLine(
                full: render { _ in true },
                plain: render { !isFaint($0) },
                dim: render { $0.contains(.dim) && !$0.contains(.invisible) }))
        }
        let location = terminal.getCursorLocation()
        let cursorRow = location.y - firstRow
        let cursor = cursorRow >= 0 && cursorRow < count ? (row: cursorRow, col: location.x) : nil
        return (lines, cursor)
    }
}
