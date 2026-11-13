import SwiftTerm
import XCTest
@testable import WhisperM8

/// Runde 5, R2: offene Claude-Ansichten und das Eingabefeld am unteren Rand.
/// Hinweistexte aus Claude Code 2.1.322; Claude zeichnet sie abgeblendet
/// (SGR 2), ebenso das Prompt-Zeichen „❯“.
final class ControllerScreenReadingTests: XCTestCase {
    private let rule = String(repeating: "─", count: 60)

    private func read(_ lines: [ControllerScreenLine], cursor: (row: Int, col: Int)? = nil) -> ControllerScreenSnapshot {
        ControllerScreenReading.read(lines: lines, cursor: cursor, detectViews: true)
    }

    /// Prompt-Zeile wie bei Claude: „❯ “ abgeblendet, danach der Text normal.
    private func prompt(_ text: String) -> ControllerScreenLine {
        let marker = "❯ "
        return ControllerScreenLine(
            full: marker + text,
            plain: "  " + text,
            dim: marker + String(repeating: " ", count: text.count))
    }

    // MARK: - Ansichten (nur abgeblendeter Text der untersten Zeilen)

    func testTranscriptFooter() {
        let lines: [ControllerScreenLine] = [.plain("⏺ Bash(ls)"), .plain("  ⎿ README.md"),
                                             .dimmed("  Showing detailed transcript · ctrl+o to toggle · ↑↓ scroll")]
        XCTAssertEqual(read(lines).openView, .transcript)
    }

    func testWorkflowsInBothStyles() {
        XCTAssertEqual(read([.plain("Dynamic workflows"),
                             .dimmed("↑/↓ to select · Enter to view · x to stop · s to save · Esc to close")]).openView,
                       .workflows)
        XCTAssertEqual(read([.plain("Dynamic workflows"), .dimmed("↑↓ select · enter view · x stop · s save · esc close")]).openView,
                       .workflows)
    }

    func testTasksDialogAndDetail() {
        XCTAssertEqual(read([.plain("Background"), .dimmed("↑/↓ to select · Enter to view · x to stop · Esc to close")]).openView,
                       .tasks)
        XCTAssertEqual(read([.plain("npm test"), .dimmed("x to stop · Esc to go back")]).openView, .tasks)
    }

    func testRewindStyleDialog() {
        XCTAssertEqual(read([.plain("Rewind"), .dimmed("Enter to continue · Esc to cancel")]).openView, .rewind)
    }

    func testFooterSelectionKeepsThePromptBox() {
        let lines: [ControllerScreenLine] = [
            .plain(rule), prompt(""), .plain(rule),
            .dimmed("  2 agents · Enter to view · x to stop · Esc to collapse · ctrl+x ctrl+k to stop all agents"),
        ]
        let snapshot = read(lines, cursor: (1, 2))
        XCTAssertEqual(snapshot.openView, .footerSelection)
        XCTAssertNotNil(snapshot.promptField)
    }

    /// Dieselben Wörter in normaler (nicht abgeblendeter) Ausgabe sind keine
    /// Ansicht — auch nicht ganz unten und ohne Eingabefeld (Review, Befund 1).
    func testHintWordsInNormalOutputAreNoView() {
        for text in ["Press Cmd+S to save · x to stop · Esc to close",
                     "↑/↓ to select · Enter to view · x to stop · Esc to close",
                     "Showing detailed transcript · ctrl+o to toggle",
                     "Enter to continue · Esc to cancel",
                     "Esc to collapse · ctrl+x ctrl+k to stop all agents"] {
            XCTAssertNil(read([.plain("⏺ Antwort"), .plain(text)]).openView, text)
        }
    }

    /// Einzelne Teile reichen nicht: „s to save“ allein ist kein /workflows.
    func testPartialHintsAreNoView() {
        XCTAssertNil(read([.dimmed("Cmd+S to save")]).openView)
        XCTAssertNil(read([.dimmed("Esc to cancel")]).openView)
        XCTAssertNil(read([.dimmed("x to stop")]).openView)
    }

    /// Ohne Eingabefeld zählen nur die untersten nicht leeren Zeilen.
    func testOnlyBottomLinesCountWithoutPromptBox() {
        let lines: [ControllerScreenLine] = [
            .dimmed("↑/↓ to select · Enter to view · x to stop · Esc to close"),
            .plain("⏺ weiter"), .plain("  läuft …"), .plain(""),
        ]
        XCTAssertNil(read(lines).openView)
    }

    // MARK: - Eingabefeld

    func testEmptyPromptIsVisiblyEmpty() {
        let field = read([.plain("⏺ Fertig."), .plain(rule), prompt(""), .plain(rule), .dimmed("  ? for shortcuts")],
                         cursor: (2, 2)).promptField
        XCTAssertEqual(field?.rows, 1)
        XCTAssertEqual(field?.isEmpty, true)
        XCTAssertEqual(field?.hasText, false)
    }

    func testTextWithCursorAtEndCountsAsText() {
        let field = read([.plain(rule), prompt("bitte die Tests"), .plain(rule)], cursor: (1, 17)).promptField
        XCTAssertEqual(field?.isEmpty, false)
        XCTAssertEqual(field?.hasText, true)
    }

    /// Ein abgeblendeter Platzhalter ist leer; ein nicht abgeblendeter mit dem
    /// Cursor am Anfang ist weder sicher Text noch sichtbar leer.
    func testPlaceholders() {
        let dimmedPlaceholder = ControllerScreenLine(
            full: "❯ Try \"refactor\"", plain: String(repeating: " ", count: 16), dim: "❯ Try \"refactor\"")
        XCTAssertEqual(read([.plain(rule), dimmedPlaceholder, .plain(rule)], cursor: (1, 2)).promptField?.isEmpty, true)
        let field = read([.plain(rule), prompt("Try \"refactor the parser\""), .plain(rule)], cursor: (1, 2)).promptField
        XCTAssertEqual(field?.isEmpty, false)
        XCTAssertEqual(field?.hasText, false)
    }

    func testMultiLineDraftWithCursorRow() {
        let lines: [ControllerScreenLine] = [.plain(rule), prompt("erste Zeile"), .plain("  zweite Zeile"),
                                             .plain("  dritte Zeile"), .plain(rule), .plain("  footer")]
        let field = read(lines, cursor: (2, 8)).promptField
        XCTAssertEqual(field?.rows, 3)
        XCTAssertEqual(field?.cursorRow, 1)
        XCTAssertEqual(field?.hasText, true)
    }

    func testCursorOutsideTheFieldIsUnknown() {
        let field = read([.plain(rule), prompt("text"), .plain(rule), .plain("footer")], cursor: (3, 0)).promptField
        XCTAssertNil(field?.cursorRow)
        XCTAssertEqual(field?.hasText, false, "ohne Cursor im Feld kein sicherer Text")
    }

    func testOldBoxedPrompt() {
        let lines: [ControllerScreenLine] = [.plain("╭" + rule + "╮"), .plain("│ > hallo  │"), .plain("╰" + rule + "╯")]
        let field = read(lines, cursor: (1, 9)).promptField
        XCTAssertEqual(field?.rows, 1)
        XCTAssertEqual(field?.isEmpty, false)
    }

    /// Ein Freigabe-Dialog ersetzt das Feld: Mit nur seiner oberen Linie gibt
    /// es kein Feld (Grundlage für Kreuz bei „arbeitet“).
    func testPermissionDialogIsNoPromptField() {
        let lines: [ControllerScreenLine] = [
            .plain("⏺ Bash(rm build.log)"), .plain(rule), .plain(" Bash command"), .plain("   rm build.log"),
            .plain(" Do you want to proceed?"), .plain(" ❯ 1. Yes"), .plain("   2. No"),
            .dimmed(" Esc to cancel · Tab to amend"),
        ]
        XCTAssertNil(read(lines, cursor: (5, 3)).promptField)
    }

    /// Trennlinie aus Tool-Ausgabe, darunter eine Zeile mit „>“ und weiter
    /// unten die obere Linie eines Dialogs: sähe aus wie ein Feld. Ein
    /// Dialog-Hinweis darunter schließt das aus.
    func testDialogHintBelowAFakeBoxIsNoPromptField() {
        let lines: [ControllerScreenLine] = [
            .plain(rule), .plain("> zitierte Zeile aus der Ausgabe"), .plain("  weiter"), .plain(rule),
            .plain(" Do you want to proceed?"), .plain(" ❯ 1. Yes"), .dimmed(" Esc to cancel"),
        ]
        XCTAssertNil(read(lines).promptField)
        // Die echte Fußzeile unter dem Feld zählt nicht als Dialog.
        let footer = read([.plain(rule), prompt(""), .plain(rule), .dimmed("  ⏵⏵ accept edits on · ? for shortcuts")])
        XCTAssertNotNil(footer.promptField)
    }

    func testNoPromptBoxWithoutPromptCharacter() {
        XCTAssertNil(read([.plain(rule), .plain("  some table row"), .plain(rule)]).promptField)
    }

    // MARK: - ← im Feld

    func testLeftArrowRule() {
        let empty = ControllerScreenSnapshot(promptField: .init(rows: 1, cursorRow: 0, cursorAtStart: true, isEmpty: true))
        let text = ControllerScreenSnapshot(promptField: .init(rows: 1, cursorRow: 0, cursorAtStart: false, isEmpty: false))
        let ambiguous = ControllerScreenSnapshot(promptField: .init(rows: 1, cursorRow: 0, cursorAtStart: true, isEmpty: false))
        XCTAssertFalse(ControllerScreenReading.fieldMayHaveText(screen: empty, tracker: true))
        XCTAssertTrue(ControllerScreenReading.fieldMayHaveText(screen: text, tracker: false))
        XCTAssertFalse(ControllerScreenReading.fieldMayHaveText(screen: ambiguous, tracker: false))
        XCTAssertTrue(ControllerScreenReading.fieldMayHaveText(screen: ambiguous, tracker: true))
        XCTAssertFalse(ControllerScreenReading.fieldMayHaveText(screen: nil, tracker: false))
        XCTAssertTrue(ControllerScreenReading.fieldMayHaveText(
            screen: ControllerScreenSnapshot(openView: .tasks), tracker: false))
    }
}

/// Dieselbe Ablesung mit echten ANSI-Folgen durch einen SwiftTerm-`Terminal`
/// (wie im PTY): Abgeblendet heißt SGR 2.
final class ControllerScreenCaptureTests: XCTestCase {
    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private let sink = Sink()
    private let dim = "\u{1b}[2m"
    private let reset = "\u{1b}[0m"

    private func screen(_ text: String, cols: Int = 100, rows: Int = 12) -> ControllerScreenSnapshot {
        let terminal = Terminal(delegate: sink, options: TerminalOptions(cols: cols, rows: rows))
        terminal.feed(text: text.replacingOccurrences(of: "\n", with: "\r\n"))
        let capture = ControllerScreenCapture.bottomLines(of: terminal)
        return ControllerScreenReading.read(lines: capture.lines, cursor: capture.cursor, detectViews: true)
    }

    private var rule: String { String(repeating: "─", count: 80) }

    func testClaudePromptWithDimmedMarkerIsRead() {
        // Leeres Feld: Cursor bleibt direkt hinter „❯ “.
        let empty = screen("⏺ Fertig.\n\(rule)\n\(dim)❯ \(reset)\u{1b}[s\n\(rule)\n\(dim)  ? for shortcuts\(reset)\u{1b}[u")
        XCTAssertEqual(empty.promptField?.isEmpty, true)
        XCTAssertEqual(empty.promptField?.cursorRow, 0)
        XCTAssertNil(empty.openView)
        let text = screen("\(rule)\n\(dim)❯ \(reset)bitte testen\u{1b}[s\n\(rule)\u{1b}[u")
        XCTAssertEqual(text.promptField?.hasText, true)
    }

    func testDimmedPlaceholderCountsAsEmpty() {
        let snapshot = screen("\(rule)\n\(dim)❯ Try \"fix the tests\"\(reset)\n\(rule)")
        XCTAssertEqual(snapshot.promptField?.isEmpty, true)
    }

    func testDimmedFooterHintsAreViews() {
        let footer = screen("\(rule)\n\(dim)❯ \(reset)\n\(rule)\n\(dim)  2 agents · Esc to collapse · ctrl+x ctrl+k to stop all agents\(reset)")
        XCTAssertEqual(footer.openView, .footerSelection)
        let tasks = screen("Background\n  ❯ npm test (running)\n\n\(dim)↑/↓ to select · Enter to view · x to stop · Esc to close\(reset)")
        XCTAssertEqual(tasks.openView, .tasks)
        let transcript = screen("⏺ Bash(ls)\n\n\(dim)Showing detailed transcript · ctrl+o to toggle\(reset)")
        XCTAssertEqual(transcript.openView, .transcript)
    }

    /// Chat-Ausgabe, die die Hinweistexte zitiert (etwa diese Datei oder die
    /// Doku), ist keine Ansicht — weder ohne noch mit Eingabefeld.
    func testQuotedHintsInChatOutputAreNoView() {
        let quoted = "↑/↓ to select · Enter to view · x to stop · s to save · Esc to close"
        XCTAssertNil(screen("⏺ Die Fußzeile lautet:\n  \(quoted)\n  Enter to continue · Esc to cancel").openView)
        XCTAssertNil(screen("⏺ \(quoted)\n\(rule)\n\(dim)❯ \(reset)\n\(rule)").openView)
        // Auch abgeblendete Tool-Ausgabe über dem Eingabefeld zählt nicht.
        XCTAssertNil(screen("\(dim)  ⎿ \(quoted)\(reset)\n\(rule)\n\(dim)❯ \(reset)\n\(rule)").openView)
    }
}
