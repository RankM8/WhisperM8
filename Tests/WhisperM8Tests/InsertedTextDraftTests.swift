import AppKit
import SwiftTerm
import XCTest
@testable import WhisperM8

/// WM8-121: Von der App eingefügter, nicht abgeschickter Text (Diktat ohne
/// Senden, „→ Jarvis“, Triage-Zeilen) bleibt ein Entwurf, auch wenn der Chat
/// von selbst einen Turn beginnt. Vorher löschte der Turn-Start die Schätzung;
/// war das Terminal hochgescrollt, stellte die Warteschlange am Turn-Ende zu,
/// hängte ihre Meldung an den Text und schickte beides mit Enter ab.
///
/// Beide Fehlerrichtungen sind geprüft: Text geht ungewollt hinaus, oder die
/// Schlange verstopft (WM8-64).
final class InsertedTextDraftTrackerTests: XCTestCase {
    private let enter: UInt16 = 36
    private let letterA: UInt16 = 0
    private let backspace: UInt16 = 51
    private let controlC: UInt16 = 8

    private func key(_ tracker: inout TerminalComposerDraftTracker, _ code: UInt16,
                     _ modifiers: NSEvent.ModifierFlags = [], status: AgentSessionRuntimeStatus? = .idle) {
        tracker.recordTerminalKey(keyCode: code, modifiers: modifiers, status: status,
                                  restoresPromptOnInterrupt: true, now: Date())
    }

    func testInsertedTextSurvivesATurnStart() {
        var tracker = TerminalComposerDraftTracker()
        tracker.recordTextInserted()
        tracker.recordSubmittedByTurnStart()
        XCTAssertTrue(tracker.mayHoldInsertedText)
        XCTAssertTrue(tracker.mayHaveUnsentInput, "zählt für send, Warteschlange und Kontowechsel")
        XCTAssertTrue(tracker.fieldMayHaveText)
    }

    func testTypedDraftIsStillClearedByATurnStart() {
        var tracker = TerminalComposerDraftTracker()
        key(&tracker, letterA)
        XCTAssertTrue(tracker.mayHaveUnsentInput)
        tracker.recordSubmittedByTurnStart()
        XCTAssertFalse(tracker.mayHaveUnsentInput, "Review W4b: Tasten aus Dialogen dürfen nicht dauerhaft sperren")
    }

    func testEnterCtrlCAndProgrammaticSubmitReleaseInsertedText() {
        var viaEnter = TerminalComposerDraftTracker()
        viaEnter.recordTextInserted()
        key(&viaEnter, enter)
        XCTAssertFalse(viaEnter.mayHaveUnsentInput)

        var viaControlC = TerminalComposerDraftTracker()
        viaControlC.recordTextInserted()
        key(&viaControlC, controlC, .control)
        XCTAssertFalse(viaControlC.mayHaveUnsentInput)

        // Ctrl+C während eines Turns leert das volle Feld ebenfalls.
        var whileWorking = TerminalComposerDraftTracker()
        whileWorking.recordTextInserted()
        key(&whileWorking, controlC, .control, status: .working)
        XCTAssertFalse(whileWorking.mayHoldInsertedText)

        var viaSubmit = TerminalComposerDraftTracker()
        viaSubmit.recordTextInserted()
        viaSubmit.recordSubmittedByTurnStart()
        viaSubmit.recordSubmitted(programmaticAt: Date())
        XCTAssertFalse(viaSubmit.mayHaveUnsentInput)
    }

    func testEditingKeysKeepInsertedText() {
        var tracker = TerminalComposerDraftTracker()
        tracker.recordTextInserted()
        key(&tracker, backspace)
        key(&tracker, enter, .shift)
        tracker.recordSubmittedByTurnStart()
        XCTAssertTrue(tracker.mayHoldInsertedText, "Rücktaste und Zeilenumbruch schicken nichts ab")
    }

    /// Eine Antwort in einem Dialog (Enter bei `awaitingInput`) gilt dem
    /// Dialog, nicht dem Eingabefeld darunter.
    func testEnterInADialogDoesNotReleaseInsertedText() {
        var tracker = TerminalComposerDraftTracker()
        tracker.recordTextInserted()
        tracker.recordSubmittedByTurnStart()
        key(&tracker, enter, status: .awaitingInput)
        XCTAssertTrue(tracker.mayHoldInsertedText)
    }

    /// Nach einem Abbruch liegt der alte Prompt im Feld. Steht dazu eingefügter
    /// Text dort, darf ein Versand das Feld nicht per Ctrl+C leeren, auch nach
    /// einem Turn-Start nicht — sonst wäre das Diktat weg.
    func testInsertedTextNextToARestoredPromptIsNeverClearedAway() {
        var tracker = TerminalComposerDraftTracker()
        tracker.recordTurnInterrupted()
        tracker.recordTextInserted()
        tracker.recordSubmittedByTurnStart()
        XCTAssertFalse(tracker.shouldClearBeforeSubmit)
        XCTAssertFalse(tracker.holdsOnlyRecalledPrompt)
    }

    func testAdoptedDraftKeepsItsKind() {
        var inserted = TerminalComposerDraftTracker()
        inserted.recordDraftAdopted(insertedText: true)
        inserted.recordSubmittedByTurnStart()
        XCTAssertTrue(inserted.mayHaveUnsentInput, "eingefügt bleibt eingefügt")

        var older = TerminalComposerDraftTracker()
        older.recordDraftAdopted(insertedText: false)
        XCTAssertTrue(older.mayHaveUnsentInput)
        older.recordSubmittedByTurnStart()
        XCTAssertFalse(older.mayHaveUnsentInput, "älteres Manifest: wie bisher ein getippter Entwurf")
    }

    func testManifestCarriesTheInsertedFlag() throws {
        var manifest = HandoverManifest(chatID: "c", kind: "claude", pid: 7, cols: 100, rows: 30,
                                        sendsInterruptOnStop: true)
        manifest.hasComposerDraft = true
        manifest.composerInsertedText = true
        let decoded = try JSONDecoder().decode(HandoverManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(decoded.composerInsertedText, true)
        let older = try JSONDecoder().decode(
            HandoverManifest.self,
            from: Data(#"{"chatID":"c","kind":"claude","pid":7,"cols":80,"rows":24,"sendsInterruptOnStop":false}"#.utf8))
        XCTAssertNil(older.composerInsertedText)
    }
}

/// Die Zusammensetzung der Warteschlange (`AgentPromptQueueDelivery.gateDecision`)
/// mit beiden Sperren: Schätzung und abgelesenes Feld.
final class InsertedTextQueueGateTests: XCTestCase {
    private func decide(_ draft: TerminalComposerDraftTracker, field: ControllerPromptField?,
                        profile: TerminalKeyboardProfile = .claudeCodeChat) -> PromptDeliveryGate.Decision {
        AgentPromptQueueDelivery.gateDecision(
            draft: draft, field: field, profile: profile,
            runtime: .idle, lifecycle: .ready, inputPending: false)
    }

    private var insertedThenTurn: TerminalComposerDraftTracker {
        var tracker = TerminalComposerDraftTracker()
        tracker.recordTextInserted()
        tracker.recordSubmittedByTurnStart()
        return tracker
    }

    /// Der Ablauf aus dem Befund: hochgescrollt liest die App nichts ab.
    func testInsertedTextHoldsTheQueueWhenTheFieldIsNotReadable() {
        XCTAssertEqual(decide(insertedThenTurn, field: nil), .draftPending)
        XCTAssertEqual(decide(insertedThenTurn, field: nil, profile: .codexChat), .draftPending)
    }

    /// Weg ins Freie: Ein sichtbar leeres Feld gibt die Meldung frei.
    func testVisiblyEmptyFieldReleasesTheQueue() {
        XCTAssertEqual(decide(insertedThenTurn, field: .emptyField), .deliver)
    }

    func testVisibleTextStillHolds() {
        XCTAssertEqual(decide(insertedThenTurn, field: .withText), .draftPending)
    }

    /// Gegenrichtung (WM8-64): Getippt, mit Enter abgeschickt, danach ein Turn:
    /// zugestellt wie bisher, auch wenn das Feld nicht ablesbar ist.
    func testTypedAndSubmittedTextDoesNotHoldTheQueue() {
        var tracker = TerminalComposerDraftTracker()
        for code: UInt16 in [0, 11, 36] {   // a, b, Enter
            tracker.recordTerminalKey(keyCode: code, modifiers: [], status: .idle,
                                      restoresPromptOnInterrupt: true, now: Date())
        }
        tracker.recordSubmittedByTurnStart()
        XCTAssertEqual(decide(tracker, field: nil), .deliver)
    }

    /// Gegenrichtung: getippt, NICHT abgeschickt, dann ein Turn — wie bisher
    /// frei (nur eingefügter Text ist neu geschützt; die Bildschirmprüfung
    /// fängt sichtbaren Text weiter ab).
    func testTypedDraftBehavesAsBefore() {
        var tracker = TerminalComposerDraftTracker()
        tracker.recordTerminalKey(keyCode: 0, modifiers: [], status: .idle,
                                  restoresPromptOnInterrupt: true, now: Date())
        tracker.recordSubmittedByTurnStart()
        XCTAssertEqual(decide(tracker, field: nil), .deliver)
        XCTAssertEqual(decide(tracker, field: .withText), .draftPending)
    }

    func testReasonInTheQueueNamesInsertedText() {
        XCTAssertEqual(AgentPromptQueueDelivery.draftPendingError(insertedThenTurn),
                       AgentPromptQueueDelivery.insertedTextError)
        var typed = TerminalComposerDraftTracker()
        typed.recordTerminalKey(keyCode: 0, modifiers: [], status: .idle, restoresPromptOnInterrupt: true, now: Date())
        XCTAssertEqual(AgentPromptQueueDelivery.draftPendingError(typed),
                       "Entwurf im Eingabefeld — wartet, bis der Chat fertig ist")
    }

    func testSendRefusesWithItsOwnMessage() {
        XCTAssertTrue(PromptDeliveryGate.sendBlockedByDraft(
            mayHaveUnsentInput: insertedThenTurn.mayHaveUnsentInput, force: false))
        XCTAssertFalse(PromptDeliveryGate.sendBlockedByDraft(
            mayHaveUnsentInput: insertedThenTurn.mayHaveUnsentInput, force: false, fieldVisiblyEmpty: true))
        XCTAssertEqual(PromptDeliveryGate.draftMessage(insertedText: true), PromptDeliveryGate.insertedTextMessage)
        XCTAssertEqual(PromptDeliveryGate.draftMessage(insertedText: false), PromptDeliveryGate.draftMessage)
    }

    /// `chats submit` lehnt eingefügten Text ab und sagt es so (Auflage zu
    /// WM8-121): kein „getippt“, dafür der Weg, der wirklich geht.
    func testSubmitRefusalNamesInsertedTextAndAWayOut() {
        let field = InsertedTextScreen.field(text: "Weiter mit WM8-12")
        XCTAssertEqual(field?.hasText, true)
        let decision = AgentControlRequestHandler.submitCheck(
            profile: .claudeCodeChat, status: .idle, approvalPending: false,
            userDraft: insertedThenTurn.mayHaveUnsentInput, insertedText: insertedThenTurn.mayHoldInsertedText,
            field: field, screenReadable: true)
        guard case .refused(let code, let message) = decision else { return XCTFail("muss ablehnen") }
        XCTAssertEqual(code, .conflict)
        XCTAssertEqual(message, AgentControlRequestHandler.submitRefusedInsertedMessage)
        XCTAssertFalse(message.contains("Entwurf des Users (getippt"), message)
        XCTAssertTrue(message.contains("zurückgehalten"), message)
        XCTAssertTrue(message.contains("chats interrupt <ref> --clear-input --force"), message)
        XCTAssertTrue(message.contains("nie ohne Rückfrage beim User"), message)
        XCTAssertTrue(message.contains("chats dequeue"), message)   // Enter bei vorgemerktem Auftrag nur nach dequeue

        var typed = TerminalComposerDraftTracker()
        typed.recordTerminalKey(keyCode: 0, modifiers: [], status: .idle, restoresPromptOnInterrupt: true, now: Date())
        guard case .refused(_, let typedMessage) = AgentControlRequestHandler.submitCheck(
            profile: .claudeCodeChat, status: .idle, approvalPending: false,
            userDraft: typed.mayHaveUnsentInput, insertedText: typed.mayHoldInsertedText,
            field: field, screenReadable: true) else { return XCTFail("muss ablehnen") }
        XCTAssertEqual(typedMessage, AgentControlRequestHandler.submitRefusedTypedMessage)
    }

    /// Wo `stuckMessage` und `visibleDraftMessage` `submit` empfehlen, vermutet
    /// die App keinen Entwurf: Ein Enter, das raus ist, aber im Feld stehen
    /// blieb, gilt als abgeschickt, und `submit` schickt ab.
    func testSubmitStillWorksWhereTheMessagesRecommendIt() {
        var stuck = TerminalComposerDraftTracker()
        stuck.recordSubmitted(programmaticAt: Date())   // Enter ging raus, Text blieb stehen
        stuck.recordSubmittedByTurnStart()
        XCTAssertEqual(AgentControlRequestHandler.submitCheck(
            profile: .claudeCodeChat, status: .idle, approvalPending: false,
            userDraft: stuck.mayHaveUnsentInput, insertedText: stuck.mayHoldInsertedText,
            field: InsertedTextScreen.field(text: "Weiter mit WM8-12"), screenReadable: true), .allowed)
    }

    func testQueueListShowsWhyAPromptWaits() {
        var prompt = QueuedPrompt(sessionID: UUID(), prompt: "Meldung an Jarvis", enqueuedAt: Date(),
                                  enqueuedBy: "Chat Ole")
        XCTAssertFalse(ChatsQueueSupport.line(for: prompt, position: 1, now: Date()).contains("wartet:"))
        prompt.lastError = AgentPromptQueueDelivery.insertedTextError
        let line = ChatsQueueSupport.line(for: prompt, position: 1, now: Date())
        XCTAssertTrue(line.contains("wartet: Eingefügter, nicht abgeschickter Text"), line)
    }
}

private extension ControllerPromptField {
    /// Über einen echten Terminal-Puffer gelesen, wie Claude das Feld zeichnet.
    static var emptyField: ControllerPromptField? { InsertedTextScreen.field(text: "") }
    static var withText: ControllerPromptField? { InsertedTextScreen.field(text: "Triage: WM8-12 schließen") }
}

enum InsertedTextScreen {
    static let rule = String(repeating: "─", count: 60)

    /// Unterer Rand mit Claudes Eingabefeld; der Cursor steht hinter dem Text.
    static func bottom(text: String) -> String {
        "\(rule)\r\n❯ \(text)\u{1b}[s\r\n\(rule)\u{1b}[u"
    }

    static func field(text: String) -> ControllerPromptField? {
        final class Sink: TerminalDelegate { func send(source: Terminal, data: ArraySlice<UInt8>) {} }
        let terminal = Terminal(delegate: Sink(), options: TerminalOptions(cols: 80, rows: 12))
        terminal.feed(text: bottom(text: text))
        let capture = ControllerScreenCapture.bottomLines(of: terminal)
        return ControllerScreenReading.read(lines: capture.lines, cursor: capture.cursor, detectViews: true).promptField
    }
}
