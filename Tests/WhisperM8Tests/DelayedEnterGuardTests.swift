import SwiftTerm
import XCTest
@testable import WhisperM8

/// WM8-75: Das verzögerte Enter nach einem Einfüge-Block darf keine Freigabe
/// bestätigen, die erst zwischen Einfügen und Enter aufgeht. Nachgestellt am
/// 14.11.2026 an Claude Code 2.1.325: Bash-Freigabe offen, Einfügen und 80 ms
/// später Enter — `rm` lief.
final class DelayedEnterGuardTests: XCTestCase {
    private let field = ControllerPromptField(rows: 1, cursorRow: 0, cursorAtStart: false, isEmpty: false)

    /// Der nachgestellte Fall: Beim Einfügen arbeitet der Chat, beim Enter
    /// wartet er auf eine Freigabe.
    func testApprovalOpeningBetweenPasteAndEnterWithholdsEnter() {
        XCTAssertFalse(DelayedEnterGuard.allowsEnter(statusAtPaste: .working, statusNow: .awaitingInput, screen: nil))
        XCTAssertFalse(DelayedEnterGuard.allowsEnter(statusAtPaste: .idle, statusNow: .awaitingInput, screen: nil))
    }

    /// `chats send` beantwortet eine schon offene Frage bewusst: wie bisher.
    func testAlreadyOpenQuestionAtPasteKeepsEnter() {
        XCTAssertTrue(DelayedEnterGuard.allowsEnter(statusAtPaste: .awaitingInput, statusNow: .awaitingInput, screen: nil))
        XCTAssertTrue(DelayedEnterGuard.allowsEnter(
            statusAtPaste: .awaitingInput, statusNow: .awaitingInput,
            screen: ControllerScreenSnapshot(dialogVisible: true)))
    }

    /// Hinkt der Status hinterher, entscheidet der Bildschirm.
    func testDialogOnScreenWithholdsEnterEvenIfStatusLags() {
        XCTAssertFalse(DelayedEnterGuard.allowsEnter(
            statusAtPaste: .working, statusNow: .working, screen: ControllerScreenSnapshot(dialogVisible: true)))
        XCTAssertFalse(DelayedEnterGuard.allowsEnter(
            statusAtPaste: .working, statusNow: .working, screen: ControllerScreenSnapshot(questionDialog: true)))
    }

    func testNormalSendStaysUnchanged() {
        XCTAssertTrue(DelayedEnterGuard.allowsEnter(statusAtPaste: .idle, statusNow: .idle, screen: nil))
        XCTAssertTrue(DelayedEnterGuard.allowsEnter(statusAtPaste: .working, statusNow: .working, screen: nil),
                      "Bildschirm nicht ablesbar (hochgescrollt): nur der Status zählt")
        XCTAssertTrue(DelayedEnterGuard.allowsEnter(
            statusAtPaste: .idle, statusNow: .working, screen: ControllerScreenSnapshot(promptField: field)))
        // Ein sichtbares Eingabefeld schlägt jede Option darüber.
        XCTAssertTrue(DelayedEnterGuard.allowsEnter(
            statusAtPaste: .working, statusNow: .working,
            screen: ControllerScreenSnapshot(promptField: field, dialogVisible: true)))
    }

    // MARK: Bildschirm durch ein echtes Terminal

    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private let sink = Sink()
    private var rule: String { String(repeating: "─", count: 80) }

    private func screen(_ text: String, detectViews: Bool = true) -> ControllerScreenSnapshot {
        let terminal = Terminal(delegate: sink, options: TerminalOptions(cols: 100, rows: 16))
        terminal.feed(text: text.replacingOccurrences(of: "\n", with: "\r\n"))
        let capture = ControllerScreenCapture.bottomLines(of: terminal)
        return ControllerScreenReading.read(lines: capture.lines, cursor: capture.cursor, detectViews: detectViews)
    }

    /// Bildschirm aus der Messung: Bash-Freigabe statt Eingabefeld.
    func testPermissionDialogCountsAsDialog() {
        let snapshot = screen("""
        ⏺ Bash(rm race.txt)
          ⎿  Waiting…
        \(rule)
         Bash command
         rm race.txt
         Do you want to proceed?
         ❯ 1. Yes
           2. No
         Esc to cancel · Tab to amend
        """)
        XCTAssertNil(snapshot.promptField)
        XCTAssertTrue(snapshot.dialogVisible)
    }

    /// Normaler Claude-Bildschirm: nummerierte Liste in der Antwort, darunter das
    /// Eingabefeld — kein Dialog.
    func testNumberedAnswerAboveThePromptIsNoDialog() {
        let snapshot = screen("""
        ⏺ Drei Schritte:
          1. Branch anlegen
          2. Tests schreiben
          3. Suite fahren
        \(rule)
        ❯ und dann die Doku
        \(rule)
          ? for shortcuts
        """)
        XCTAssertNotNil(snapshot.promptField)
        XCTAssertFalse(snapshot.dialogVisible)
    }

    /// Ein eigener Entwurf, der mit „1. “ beginnt, lässt die Feld-Erkennung das
    /// Feld verwerfen; das ist kein Dialog (Review-Befund 7).
    func testOwnNumberedDraftIsNoDialog() {
        XCTAssertTrue(DelayedEnterGuard.looksLikeOption("1. Branch anlegen\n2. Tests"))
        XCTAssertFalse(DelayedEnterGuard.looksLikeOption("Bitte zuerst den Branch"))
        let screen = ControllerScreenSnapshot(dialogVisible: true)
        XCTAssertTrue(DelayedEnterGuard.allowsEnter(
            statusAtPaste: .working, statusNow: .working, screen: screen, textLooksLikeOption: true))
        XCTAssertFalse(DelayedEnterGuard.allowsEnter(
            statusAtPaste: .working, statusNow: .working, screen: ControllerScreenSnapshot(questionDialog: true),
            textLooksLikeOption: true), "Ein Frage-Dialog mit festem Anker zählt trotzdem")
    }

    /// Status unbekannt: Der Bildschirm entscheidet.
    func testUnknownStatusFallsBackToScreen() {
        XCTAssertFalse(DelayedEnterGuard.allowsEnter(
            statusAtPaste: nil, statusNow: nil, screen: ControllerScreenSnapshot(dialogVisible: true)))
        XCTAssertTrue(DelayedEnterGuard.allowsEnter(statusAtPaste: nil, statusNow: nil, screen: nil))
    }

    /// Codex: dessen Eingabefeld kennt die Feld-Erkennung nicht — `read` setzt
    /// `dialogVisible` deshalb nur für Claude (`detectViews`).
    func testCodexScreenNeverReportsDialog() {
        let snapshot = screen("""
        • Plan:
          1. Datei lesen
          2. Ändern
        › Weiter so
        """, detectViews: false)
        XCTAssertFalse(snapshot.dialogVisible)
    }
}
