import XCTest
@testable import WhisperM8

/// WM8-119: Das Enter nach einem Einfüge-Block wartet bei einem ruhenden
/// Claude-Chat, bis der Text im Feld steht. Claude Code liest eingefügte
/// Bildpfade erst ein; ein Enter in dieser Zeit verwirft es, und die Meldung
/// blieb im Feld stehen (`queue_stuck_in_field`, 16.11.2026).
final class DelayedEnterLandingTests: XCTestCase {
    /// Leeres Feld wie vor dem Einfügen.
    private let pristine = ControllerPromptField(rows: 1, cursorRow: 0, cursorAtStart: true, isEmpty: true, isBlank: true)
    /// Leeres Feld mit grauem Vorschlag: zählt auch als „noch nicht angekommen“.
    private let suggestion = ControllerPromptField(rows: 1, cursorRow: 0, cursorAtStart: true, isEmpty: true, isBlank: false)
    /// Der Text steht da („[Image #1] [Pasted text #2 +30 lines]“, Cursor dahinter).
    private let landed = ControllerPromptField(rows: 1, cursorRow: 0, cursorAtStart: false, isEmpty: false)
    private let landedMultiline = ControllerPromptField(rows: 3, cursorRow: 2, cursorAtStart: false, isEmpty: false)

    private func step(profile: TerminalKeyboardProfile = .claudeCodeChat,
                      status: AgentSessionRuntimeStatus? = .idle,
                      field: ControllerPromptField?, elapsed: TimeInterval = 0.08,
                      waited: Bool = false, touched: Bool = false) -> DelayedEnterLanding.Step {
        DelayedEnterLanding.step(profile: profile, statusAtPaste: status, field: field,
                                 elapsed: elapsed, waited: waited, touched: touched)
    }

    /// Der Normalfall: reiner Text steht nach 80 ms im Feld, Enter sofort wie bisher.
    func testLandedTextSendsAtFirstAttempt() {
        XCTAssertEqual(step(field: landed), .send)
        XCTAssertEqual(step(field: landedMultiline), .send)
    }

    /// Der Vorfall: Bilder werden noch eingelesen, das Feld ist noch leer.
    func testEmptyFieldWaitsForPaste() {
        XCTAssertEqual(step(field: pristine), .wait)
        XCTAssertEqual(step(field: suggestion), .wait)
        XCTAssertEqual(step(field: pristine, elapsed: 1.5, waited: true), .wait)
        // Sobald der Text da ist: Enter.
        XCTAssertEqual(step(field: landed, elapsed: 0.6, waited: true), .send)
    }

    /// Nach der Frist geht das Enter wie früher; das Nachsehen danach meldet,
    /// wenn der Text stehen bleibt.
    func testGivesUpAfterMaxWait() {
        XCTAssertEqual(step(field: pristine, elapsed: DelayedEnterLanding.maxWaitSeconds, waited: true), .send)
        XCTAssertEqual(step(field: pristine, elapsed: DelayedEnterLanding.maxWaitSeconds - 0.05, waited: true), .wait)
    }

    /// Tippt der User in die Wartezeit hinein, schickte das Enter seinen Text
    /// mit ab: dann kein Enter, auch wenn das Feld jetzt Text zeigt.
    func testTouchedFieldWhileWaitingSkipsEnter() {
        XCTAssertEqual(step(field: landed, elapsed: 0.5, waited: true, touched: true), .skip)
        XCTAssertEqual(step(field: pristine, elapsed: 0.5, waited: true, touched: true), .skip)
        XCTAssertEqual(step(field: nil, elapsed: 0.5, waited: true, touched: true), .skip)
    }

    /// Beim ersten Versuch wie bisher: Ein angekommener Text bekommt sein Enter.
    func testTouchedBeforeFirstAttemptKeepsOldBehaviour() {
        XCTAssertEqual(step(field: landed, touched: true), .send)
    }

    /// Nicht ablesbar, Cursor außerhalb des Felds, Codex, Shell oder offene
    /// Rückfrage: kein Warten, Enter wie bisher.
    func testOnlyIdleClaudeWithReadableFieldWaits() {
        XCTAssertEqual(step(field: nil), .send)
        XCTAssertEqual(step(field: ControllerPromptField(rows: 1, cursorRow: nil, cursorAtStart: false, isEmpty: true)), .send)
        XCTAssertEqual(step(profile: .codexChat, field: pristine), .send)
        XCTAssertEqual(step(profile: .plainShell, field: pristine), .send)
        XCTAssertEqual(step(status: .awaitingInput, field: pristine), .send)
        XCTAssertEqual(step(status: .working, field: pristine), .send)
        XCTAssertEqual(step(status: nil, field: pristine), .send)
    }

    func testNotLandedYetNeedsSingleEmptyRowWithCursorAtStart() {
        XCTAssertTrue(DelayedEnterLanding.notLandedYet(pristine))
        XCTAssertTrue(DelayedEnterLanding.notLandedYet(suggestion))
        XCTAssertFalse(DelayedEnterLanding.notLandedYet(landed))
        XCTAssertFalse(DelayedEnterLanding.notLandedYet(landedMultiline))
        // Text steht da, der Cursor wurde an den Anfang gesetzt: angekommen.
        XCTAssertFalse(DelayedEnterLanding.notLandedYet(
            ControllerPromptField(rows: 1, cursorRow: 0, cursorAtStart: true, isEmpty: false)))
    }

    /// `chats send` und die Warteschlange prüfen erst nach dem entschiedenen
    /// Enter, ob der Text raus ist; vorher hieße ein leeres Feld „abgeschickt“.
    @MainActor
    func testEnterWasWithheldWaitsWhileEnterIsPending() async {
        let sessionID = UUID()
        let started = Date()
        AgentTerminalController.pendingEnterSince[sessionID] = started
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            AgentTerminalController.pendingEnterSince[sessionID] = nil
        }
        let withheld = await AgentTerminalController.enterWasWithheld(sessionID: sessionID, clearedInput: false,
                                                                      since: started)
        XCTAssertFalse(withheld)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.5)
        XCTAssertNil(AgentTerminalController.pendingEnterSince[sessionID])
    }
}
