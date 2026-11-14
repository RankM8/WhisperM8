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
