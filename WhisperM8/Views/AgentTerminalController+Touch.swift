import AppKit
import SwiftTerm

// Finger-Bedienung am Touch-Display (WM8-136): Wohin ein Finger-Scroll geht.
// Erkennung und Schwung stehen in `TerminalTouchGestures`, die reine Logik in
// `TerminalTouchScrolling`.

extension AgentTerminalController {
    /// Mausrad-Schritte, die ein einzelner Finger-Schritt höchstens an eine TUI
    /// schickt (wie `scrollHistory` für den Controller).
    static let maxTouchWheelStepsPerFrame = 30

    func installTouchGestures() {
        touchGestures = TerminalTouchGestures(attachedTo: terminal) { [weak self] lines, location in
            self?.scrollForTouch(lines: lines, at: location) ?? false
        }
    }

    /// Scrollt um `lines` Zeilen (positiv = hoch, ältere Zeilen), genauso wie es
    /// das Trackpad an dieser Stelle täte (`TerminalTouchScrollRoute`).
    /// `false`, wenn sich der Verlauf nicht mehr bewegt.
    func scrollForTouch(lines: Int, at location: NSPoint) -> Bool {
        guard lines != 0 else { return true }
        let term = terminal.getTerminal()
        let route = TerminalTouchScrollRoute.decide(
            isAlternateBuffer: term.isCurrentBufferAlternate,
            mouseReportingActive: terminal.allowMouseReporting && term.mouseMode != .off,
            processRunning: isRunning
        )
        let steps = min(abs(lines), Self.maxTouchWheelStepsPerFrame)
        switch route {
        case .ignore:
            return false
        case .wheelToAlternateScreen:
            let sequence = TerminalScrollStep.wheelSequence(up: lines > 0)
            for _ in 0..<steps { terminal.send(txt: sequence) }
            return true
        case .wheelToMouseReporting:
            let cell = touchCell(at: location, columns: term.cols, rows: term.rows)
            let flags = term.encodeButton(
                button: lines > 0 ? 4 : 5, release: false, shift: false, meta: false, control: false
            )
            for _ in 0..<steps { term.sendEvent(buttonFlags: flags, x: cell.column, y: cell.row) }
            return true
        case .scrollback:
            let before = term.getTopVisibleRow()
            if lines > 0 {
                terminal.scrollUp(lines: lines)
            } else {
                terminal.scrollDown(lines: -lines)
            }
            return term.getTopVisibleRow() != before
        }
    }

    /// Zelle unter dem Finger, 0-basiert, Zeile von oben.
    private func touchCell(at location: NSPoint, columns: Int, rows: Int) -> (column: Int, row: Int) {
        let size = terminal.bounds.size
        guard columns > 0, rows > 0, size.width > 0, size.height > 0 else { return (0, 0) }
        let fromTop = terminal.isFlipped ? location.y : size.height - location.y
        let column = Int(location.x / (size.width / CGFloat(columns)))
        let row = Int(fromTop / (size.height / CGFloat(rows)))
        return (min(max(column, 0), columns - 1), min(max(row, 0), rows - 1))
    }
}
