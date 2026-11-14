import SwiftTerm
import XCTest
@testable import WhisperM8

/// WM8-67: Codex meldet Freigaben der App nicht. Nachgestellt am 14.11.2026 an
/// einem Wegwerf-Codex (CLI 0.169.0, eigenes CODEX_HOME, Schein-Modell): Ein
/// Einfüge-Block im offenen Freigabe-Dialog wird ignoriert, das Enter danach
/// wählt „1. Yes, proceed“ — der Befehl lief, obwohl „nein“ eingefügt war.
/// Erkannt wird die Freigabe deshalb am Bildschirm.
final class CodexApprovalScreenTests: XCTestCase {
    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }
    private let sink = Sink()

    private func screen(_ text: String, codex: Bool = true) -> ControllerScreenSnapshot {
        let terminal = Terminal(delegate: sink, options: TerminalOptions(cols: 100, rows: 16))
        terminal.feed(text: text.replacingOccurrences(of: "\n", with: "\r\n"))
        let capture = ControllerScreenCapture.bottomLines(of: terminal)
        return ControllerScreenReading.read(
            lines: capture.lines, cursor: capture.cursor, detectViews: !codex, detectCodexApproval: codex)
    }

    /// So zeichnet Codex 0.169.0 die Freigabe (Pfad gekürzt). Die Hinweiszeile
    /// ist teils abgeblendet, teils fett.
    private let approval = """
    › Bitte lege die Datei MARKER an.
    • Running touch /tmp/beleg/MARKER

      Would you like to run the following command?

      Reason: Datei MARKER anlegen

      $ touch /tmp/beleg/MARKER

    \u{1b}[7m\u{1b}[1m› 1. Yes, proceed (y)\u{1b}[0m
      2. Yes, and don't ask again for commands that start with `touch /tmp/beleg/MARKER` (p)
      3. No, and tell Codex what to do differently (\u{1b}[1mesc\u{1b}[22m)

      \u{1b}[2mPress \u{1b}[22m\u{1b}[1menter\u{1b}[22m\u{1b}[2m to confirm or \u{1b}[22m\u{1b}[1mesc\u{1b}[22m\u{1b}[2m to cancel\u{1b}[22m
    """

    func testCodexApprovalIsRecognised() {
        XCTAssertTrue(screen(approval).codexApproval)
    }

    /// Nur Codex: Bei Claude liest `read` die Codex-Freigabe nie.
    func testOnlyCodexReadsItsApproval() {
        XCTAssertFalse(screen(approval, codex: false).codexApproval)
    }

    /// Bricht die Hinweiszeile um oder fehlt sie, tragen die festen Optionen.
    func testFixedOptionsAloneAreEnough() {
        let withoutHint = """
          Would you like to run the following command?
        › 1. Yes, proceed (y)
          2. No, and tell Codex what to do differently (esc)
        """
        XCTAssertTrue(screen(withoutHint).codexApproval)
    }

    /// Normale Arbeit: nummerierte Listen in der Ausgabe und das Eingabefeld
    /// sind keine Freigabe.
    func testOrdinaryCodexScreenIsNoApproval() {
        let working = """
        • Plan:
          1. Datei lesen
          2. Ändern und mit enter bestätigen
        • Ran swift build
          └ Build complete

        › Ask Codex to do anything
          ← for agents · ? for shortcuts
        """
        XCTAssertFalse(screen(working).codexApproval)
        // Ausgabe, die den Satz zitiert, ohne Optionen darüber: keine Freigabe.
        let quoted = """
        • Codex zeigt dann „Press enter to confirm or esc to cancel“.

        › Ask Codex to do anything
        """
        XCTAssertFalse(screen(quoted).codexApproval)
    }

    /// WM8-107: Eine nummerierte Liste in Codex' eigener Antwort, die eine der
    /// festen Optionen zitiert, ist keine Freigabe — es braucht beide zugleich.
    func testNumberedListInCodexAnswerIsNoApproval() {
        let answer = """
        • Im Dialog gibt es drei Wege:
          1. Yes, proceed (y) — der Befehl läuft
          2. Abbrechen mit esc
          3. Später entscheiden

        › Ask Codex to do anything
        """
        XCTAssertFalse(screen(answer).codexApproval)
        let otherOnly = """
        • Antwort:
          1. No, and tell Codex what to do differently
          2. Etwas anderes
        """
        XCTAssertFalse(screen(otherOnly).codexApproval)
    }

    /// Umgebrochene Optionen (schmales Fenster) zählen trotzdem.
    func testWrappedOptionsStillCount() {
        let narrow = """
        › 1. Yes, proceed (y)
          2. No, and tell Codex what to do
             differently (esc)
        """
        XCTAssertTrue(screen(narrow).codexApproval)
    }

    // MARK: Hochgescrollt (WM8-107)

    private func scrolledTerminal(scrollback: Int, outputLines: Int) -> Terminal {
        let terminal = Terminal(delegate: sink, options: TerminalOptions(cols: 100, rows: 16, scrollback: scrollback))
        let output = (1...outputLines).map { "Ausgabe Zeile \($0)" }.joined(separator: "\n")
        terminal.feed(text: (output + "\n" + approval).replacingOccurrences(of: "\n", with: "\r\n"))
        // Ganz nach oben gescrollt, wie beim Lesen der Ausgabe.
        terminal.buffer.yDisp = 0
        return terminal
    }

    /// Hochgescrollt zeigt `getLine` den Ausschnitt oben, die Freigabe steht
    /// trotzdem unten auf dem lebendigen Bildschirm und wird erkannt.
    func testApprovalIsFoundWhileScrolledUp() {
        let terminal = scrolledTerminal(scrollback: 500, outputLines: 200)
        let visible = ControllerScreenCapture.bottomLines(of: terminal).lines.map(\.full)
        XCTAssertFalse(ControllerScreenReading.isCodexApproval(visible), "Ausschnitt oben zeigt keine Freigabe")
        let live = ControllerScreenCapture.liveBottomLines(of: terminal).lines.map(\.full)
        XCTAssertTrue(ControllerScreenReading.isCodexApproval(live))
        XCTAssertTrue(live.contains { $0.contains("Press enter to confirm") })
    }

    /// Auch wenn der Verlauf voll ist und oben Zeilen wegfallen (Zählung ab
    /// `totalLinesTrimmed`).
    func testApprovalIsFoundWithTrimmedScrollback() {
        let terminal = scrolledTerminal(scrollback: 40, outputLines: 300)
        XCTAssertGreaterThan(terminal.buffer.totalLinesTrimmed, 0)
        let live = ControllerScreenCapture.liveBottomLines(of: terminal).lines.map(\.full)
        XCTAssertTrue(ControllerScreenReading.isCodexApproval(live))
    }

    /// Ganz unten liefern beide Wege dieselben Zeilen.
    func testLiveAndVisibleAgreeAtTheBottom() {
        let terminal = Terminal(delegate: sink, options: TerminalOptions(cols: 100, rows: 16, scrollback: 500))
        let output = (1...60).map { "Zeile \($0)" }.joined(separator: "\n")
        terminal.feed(text: (output + "\n" + approval).replacingOccurrences(of: "\n", with: "\r\n"))
        let visible = ControllerScreenCapture.bottomLines(of: terminal)
        let live = ControllerScreenCapture.liveBottomLines(of: terminal)
        XCTAssertEqual(visible.lines, live.lines)
        XCTAssertEqual(visible.cursor?.row, live.cursor?.row)
    }

    // MARK: Enter und `chats send`

    /// Das verzögerte Enter bleibt aus, auch wenn der Status „arbeitet“ zeigt
    /// (Codex meldet kein „wartet“) und auch bei Text, der wie eine Option beginnt.
    func testDelayedEnterIsWithheldInCodexApproval() {
        let shot = ControllerScreenSnapshot(codexApproval: true)
        XCTAssertFalse(DelayedEnterGuard.allowsEnter(statusAtPaste: .working, statusNow: .working, screen: shot))
        XCTAssertFalse(DelayedEnterGuard.allowsEnter(
            statusAtPaste: .idle, statusNow: .idle, screen: shot, textLooksLikeOption: true))
        XCTAssertTrue(DelayedEnterGuard.allowsEnter(
            statusAtPaste: .working, statusNow: .working, screen: ControllerScreenSnapshot()))
    }

    func testChatsSendRefusesCodexApproval() {
        XCTAssertTrue(DelayedEnterGuard.approvalPending(
            status: .working, lifecycle: nil, screen: ControllerScreenSnapshot(codexApproval: true)))
        XCTAssertFalse(DelayedEnterGuard.approvalPending(
            status: .working, lifecycle: nil, screen: ControllerScreenSnapshot()))
    }

    /// Der Weg des Diktats: Meldet der Schreiber „wartet“, bleibt der Text in
    /// der Zwischenablage, mit und ohne Senden.
    func testDictationIntoCodexApprovalStaysOnClipboard() {
        let id = UUID()
        for submit in [true, false] {
            let decision = DictationDeliveryRouter.decide(
                delivery: DictationDelivery(target: .agentChat(sessionID: id), submit: submit),
                text: "nein, lass das", chatState: { _ in .awaitingInput })
            XCTAssertEqual(decision, .clipboardOnly(.decisionPending))
        }
    }
}
