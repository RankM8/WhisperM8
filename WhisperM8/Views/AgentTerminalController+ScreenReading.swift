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
        let count = min(ControllerScreenReading.lineCount, swiftTerm.rows)
        let firstRow = swiftTerm.rows - count
        var lines: [String] = []
        lines.reserveCapacity(count)
        for row in firstRow..<swiftTerm.rows {
            let text = swiftTerm.getLine(row: row)?.translateToString(
                trimRight: true, skipNullCellsFollowingWide: true,
                characterProvider: { cell in
                    // Abgeblendet oder unsichtbar zählt nicht als Text (Platzhalter).
                    let style = cell.attribute.style
                    if style.contains(.dim) || style.contains(.invisible) { return " " }
                    return cell.getCharacter()
                }) ?? ""
            lines.append(text)
        }
        let location = swiftTerm.getCursorLocation()
        let cursorRow = location.y - firstRow
        let cursor = cursorRow >= 0 && cursorRow < count ? (row: cursorRow, col: location.x) : nil
        return ControllerScreenReading.read(lines: lines, cursor: cursor, detectViews: profile == .claudeCodeChat)
    }
}
