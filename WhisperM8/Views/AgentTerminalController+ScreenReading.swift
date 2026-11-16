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
        // Erst den Rückstand einer gedrosselten Pane verarbeiten, dann prüfen,
        // ob die Ansicht unten steht (`controllerBottomLines`).
        terminal.flushPendingOutput()
        let swiftTerm = terminal.getTerminal()
        guard !isScrolledBack else {
            // Hochgescrollt zeigt `getLine` den Ausschnitt, nicht den lebendigen
            // Bildschirm. Bei Codex dort trotzdem die Freigabe lesen (WM8-107):
            // Gerade bei offener Freigabe scrollt man hoch, um zu lesen, was Codex
            // vorhat. Alles andere bleibt hochgescrollt unbekannt wie bisher;
            // ohne Freigabe deshalb weiter `nil`.
            guard profile == .codexChat else { return nil }
            PerformanceCounters.shared.count(.controllerScreenRead)
            let live = ControllerScreenCapture.liveBottomLines(of: swiftTerm)
            guard ControllerScreenReading.isCodexApproval(live.lines.map(\.full)) else { return nil }
            return ControllerScreenSnapshot(codexApproval: true)
        }
        PerformanceCounters.shared.count(.controllerScreenRead)
        let capture = terminal.controllerBottomLines()
        return ControllerScreenReading.read(
            lines: capture.lines, cursor: capture.cursor, detectViews: profile == .claudeCodeChat,
            detectCodexApproval: profile == .codexChat)
    }

    /// Bildschirm für Prüfungen, die dadurch nur strenger werden (WM8-123):
    /// Sendesperre bei Text im Feld, Freigabe- und Dialog-Erkennung, offene
    /// Ansicht. Bei Claude auch hochgescrollt vom lebendigen Bildschirm; der
    /// Cursor kommt ohnehin von dort (`getCursorLocation` ist `buffer.y`),
    /// Zeilen und Cursor passen also zusammen. `atBottom`: Die Ansicht steht
    /// unten; nur dann darf ein leeres Feld etwas freigeben. Einmal je
    /// Zustellversuch bzw. `send`, nie je Taste.
    func sendCheckScreen() -> (snapshot: ControllerScreenSnapshot?, atBottom: Bool) {
        guard let capture = claudeSendCheckLines() else {
            return (controllerScreenSnapshot(), !isScrolledBack)
        }
        return (ControllerScreenReading.read(lines: capture.lines, cursor: capture.cursor, detectViews: true),
                capture.atBottom)
    }

    /// Eingabefeld für `send` und Warteschlange (WM8-123), dieselbe Ablesung
    /// wie `sendCheckScreen`, dazu die Ansichten, die nur die Sendeprüfung
    /// kennt (`ComposerFieldReading.viewWithoutUsableField`).
    func composerFieldForSendCheck() -> ComposerFieldReading {
        guard let capture = claudeSendCheckLines() else { return .unreadable }
        let snapshot = ControllerScreenReading.read(lines: capture.lines, cursor: capture.cursor, detectViews: true)
        let view = snapshot.openView?.rawValue
            ?? ComposerFieldReading.viewWithoutUsableField(capture.lines.map(\.full))
        return ComposerFieldReading(field: snapshot.promptField, atBottom: capture.atBottom, openView: view)
    }

    /// Untere Zeilen eines laufenden Claude-Chats: unten wie der Controller,
    /// hochgescrollt vom lebendigen Bildschirm. `nil` bei Codex und Shell.
    private func claudeSendCheckLines()
        -> (lines: [ControllerScreenLine], cursor: (row: Int, col: Int)?, atBottom: Bool)? {
        guard isRunning, command.keyboardProfile == .claudeCodeChat else { return nil }
        terminal.flushPendingOutput()
        PerformanceCounters.shared.count(.controllerScreenRead)
        if isScrolledBack {
            let live = ControllerScreenCapture.liveBottomLines(of: terminal.getTerminal())
            return (live.lines, live.cursor, false)
        }
        let capture = terminal.controllerBottomLines()
        return (capture.lines, capture.cursor, true)
    }

    /// Die Ansicht ist hochgescrollt: normaler Puffer mit Verlauf, und der
    /// Ausschnitt steht nicht ganz unten. Im Alternate-Puffer nie (dort gibt
    /// es keinen Verlauf). Einzige Quelle für „hochgescrollt“: Sendeschutz und
    /// Bildschirm-Lesen (WM8-107) ebenso wie Kreis „Ans Ende“ (WM8-116). Liest
    /// nur Zahlen der Ansicht, kein Zeilen-Text.
    var isScrolledBack: Bool {
        !(terminal.getTerminal().isCurrentBufferAlternate || !terminal.canScroll || terminal.scrollPosition >= 1)
    }

    /// Um `step` Bildschirme blättern (R1 + rechter Stick, WM8-116), mit
    /// Überlappung (`ControllerScrollPaging`). Im Alternate-Puffer wie das
    /// Scrollen als Mausrad an die TUI (höchstens 30 Schritte je Aufruf).
    func scrollHistoryPage(_ step: Int) {
        scrollHistory(lines: ControllerScrollPaging.lines(step: step, rows: terminal.getTerminal().rows))
    }

    /// Ganz ans Ende (Kreis im hochgescrollten Chat, WM8-116). Schickt nichts
    /// an das Programm; im Alternate-Puffer ohne Wirkung.
    func scrollHistoryToBottom() {
        guard isScrolledBack else { return }
        terminal.scroll(toPosition: 1)
    }

    /// Steht unten ein Freigabe-Dialog von Codex (WM8-67)? Nur Codex, nur ganz
    /// unten ablesbar; hochgescrollt `false` (dann zählt nur der Status).
    func codexApprovalOnScreen() -> Bool {
        guard command.keyboardProfile == .codexChat else { return false }
        return controllerScreenSnapshot()?.codexApproval ?? false
    }
}

extension QuietableTerminalView {
    /// Unterer Rand für den Controller. Vorher den Puffer der Drosselung
    /// leeren: Eine gedrosselte Pane (Raster ohne Fokus, Chat in zwei
    /// Workspaces) zeigte sonst bis zu 80 ms alte Bytes — etwa noch das
    /// Eingabefeld, obwohl Claude schon einen Freigabe-Dialog geschickt hat.
    func controllerBottomLines() -> (lines: [ControllerScreenLine], cursor: (row: Int, col: Int)?) {
        flushPendingOutput()
        return ControllerScreenCapture.bottomLines(of: getTerminal())
    }
}

/// Liest die unteren Zeilen eines SwiftTerm-Terminals in den drei Fassungen
/// von `ControllerScreenLine`. Getrennt vom Controller, damit Tests echte
/// ANSI-Folgen durch einen `Terminal` schicken können.
enum ControllerScreenCapture {
    static func bottomLines(of terminal: Terminal) -> (lines: [ControllerScreenLine], cursor: (row: Int, col: Int)?) {
        bottomLines(of: terminal) { terminal.getLine(row: $0) }
    }

    /// Wie `bottomLines`, aber immer vom lebendigen Bildschirm, auch wenn die
    /// Ansicht hochgescrollt ist (WM8-107). Unten steht genau das, was das
    /// Programm zuletzt gezeichnet hat; der Cursor zählt ohnehin dort.
    static func liveBottomLines(of terminal: Terminal) -> (lines: [ControllerScreenLine], cursor: (row: Int, col: Int)?) {
        let top = liveScreenTop(of: terminal)
        return bottomLines(of: terminal) { terminal.getScrollInvariantLine(row: top + $0) }
    }

    /// Erste Zeile des lebendigen Bildschirms, gezählt wie
    /// `getScrollInvariantLine`. SwiftTerm hält die Grenze (`yBase`) intern;
    /// sie ist das Pufferende minus die Bildschirmhöhe — dieselbe Rechnung wie
    /// SwiftTerms `scrollPosition` („ganz unten“). Das Pufferende sucht eine
    /// Probe über die gültigen Zeilen: verdoppeln, dann halbieren, also wenige
    /// Zugriffe auch bei 10.000 Zeilen Verlauf.
    static func liveScreenTop(of terminal: Terminal) -> Int {
        let buffer = terminal.buffer
        // Bis hierhin gibt es sicher Zeilen: Der Ausschnitt liegt nie unter dem
        // lebendigen Bildschirm.
        var valid = buffer.totalLinesTrimmed + buffer.yDisp + terminal.rows
        var step = 1
        var invalid = valid
        while terminal.getScrollInvariantLine(row: invalid) != nil {
            valid = invalid + 1
            invalid += step
            step *= 2
        }
        // Alles unter `valid` gibt es, `invalid` nicht.
        while valid < invalid {
            let middle = (valid + invalid) / 2
            if terminal.getScrollInvariantLine(row: middle) != nil { valid = middle + 1 } else { invalid = middle }
        }
        return valid - terminal.rows
    }

    private static func bottomLines(
        of terminal: Terminal, line lineAt: (Int) -> BufferLine?
    ) -> (lines: [ControllerScreenLine], cursor: (row: Int, col: Int)?) {
        let count = min(ControllerScreenReading.lineCount, terminal.rows)
        let firstRow = terminal.rows - count
        var lines: [ControllerScreenLine] = []
        lines.reserveCapacity(count)
        for row in firstRow..<terminal.rows {
            guard let line = lineAt(row) else {
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
