import AppKit
import XCTest
@testable import WhisperM8

/// WM8-123, Punkt 3: Ein Auftrag von `chats send` oder der Warteschlange,
/// dessen Enter wegen einer Freigabe zurückgehalten wurde, stammt vom
/// Absender, nicht von Giuliano. `chats submit` darf ihn abschicken, solange
/// seitdem niemand im Feld etwas getippt, eingefügt oder geholt hat.
///
/// Beide Richtungen: Text des Users geht nie raus; der Auftrag des Absenders
/// bleibt nicht ohne Grund liegen und kommt nicht doppelt.
final class WithheldDeliveryTrackerTests: XCTestCase {
    private let enter: UInt16 = 36
    private let letterA: UInt16 = 0
    private let backspace: UInt16 = 51
    private let tab: UInt16 = 48
    private let escape: UInt16 = 53
    private let arrowUp: UInt16 = 126
    private let controlC: UInt16 = 8
    private let keyV: UInt16 = 9

    private func key(_ tracker: inout TerminalComposerDraftTracker, _ code: UInt16,
                     _ modifiers: NSEvent.ModifierFlags = [], status: AgentSessionRuntimeStatus? = .idle) {
        tracker.recordTerminalKey(keyCode: code, modifiers: modifiers, status: status,
                                  restoresPromptOnInterrupt: true, now: Date())
    }

    /// Wie in `pastePrompt`: Einfügen mit geplantem Enter, dann zurückgehalten.
    private func withheld(claim: Bool = true, queuedPromptID: UUID? = nil) -> TerminalComposerDraftTracker {
        var tracker = TerminalComposerDraftTracker()
        tracker.recordSubmitted(programmaticAt: Date())
        tracker.recordDeliveryWithheld()
        if claim { XCTAssertTrue(tracker.claimWithheldDelivery(queuedPromptID: queuedPromptID)) }
        return tracker
    }

    func testClaimedDeliveryIsSubmittableAlsoAfterATurnStart() {
        let id = UUID()
        var tracker = withheld(queuedPromptID: id)
        XCTAssertTrue(tracker.mayHaveUnsentInput, "send, Warteschlange und Kontowechsel sehen weiter Text im Feld")
        tracker.recordSubmittedByTurnStart()
        XCTAssertEqual(tracker.submittableWithheldDelivery?.queuedPromptID, id)
    }

    /// Diktat mit Senden: Das Enter wird genauso zurückgehalten, aber niemand
    /// beansprucht den Text; er gehört Giuliano.
    func testUnclaimedTextIsNeverSubmittable() {
        let tracker = withheld(claim: false)
        XCTAssertTrue(tracker.mayHoldInsertedText)
        XCTAssertNil(tracker.submittableWithheldDelivery)
    }

    func testAnythingAddedAfterwardsMakesItTheUsersText() {
        let edits: [(String, (inout TerminalComposerDraftTracker) -> Void)] = [
            ("Buchstabe", { self.key(&$0, self.letterA) }),
            ("Rücktaste", { self.key(&$0, self.backspace) }),
            ("Tab", { self.key(&$0, self.tab) }),
            ("Cmd+V", { self.key(&$0, self.keyV, .command) }),
            ("Shift+Enter", { self.key(&$0, self.enter, .shift) }),
            ("Diktat oder → Jarvis", { $0.recordTextInserted() }),
            ("↑ vom Controller", { $0.recordHistoryRecall(isClaude: true) }),
            ("→ Vorschlag", { $0.recordSuggestionAccepted() }),
        ]
        for (name, edit) in edits {
            var tracker = withheld()
            edit(&tracker)
            XCTAssertNil(tracker.submittableWithheldDelivery, name)
            tracker.recordSubmittedByTurnStart()
            XCTAssertNil(tracker.submittableWithheldDelivery, "\(name), auch nach einem Turn-Start")
        }
    }

    func testEscapeAndArrowsLeaveItAlone() {
        var tracker = withheld()
        key(&tracker, escape)
        key(&tracker, arrowUp)
        XCTAssertNotNil(tracker.submittableWithheldDelivery)
    }

    /// Tasten im Freigabe-Dialog gehen an den Dialog, nicht ins Feld.
    func testKeysInTheApprovalDialogLeaveItAlone() {
        var tracker = withheld()
        key(&tracker, letterA, status: .awaitingInput)
        key(&tracker, enter, status: .awaitingInput)
        XCTAssertNotNil(tracker.submittableWithheldDelivery)
    }

    func testEnterCtrlCAndSubmitEndIt() {
        var viaEnter = withheld()
        key(&viaEnter, enter)
        XCTAssertNil(viaEnter.withheldDelivery)
        XCTAssertFalse(viaEnter.mayHaveUnsentInput)

        var viaControlC = withheld()
        key(&viaControlC, controlC, .control)
        XCTAssertNil(viaControlC.withheldDelivery)

        var viaSubmit = withheld()
        viaSubmit.recordSubmitted(programmaticAt: Date())
        XCTAssertNil(viaSubmit.withheldDelivery)
    }

    /// Zwischen Zurückhalten (80 ms) und Beanspruchen (180 ms) getippt: Dann
    /// gehört der Text auch dem User, der Anspruch scheitert.
    func testClaimAfterTypingFails() {
        var tracker = withheld(claim: false)
        key(&tracker, letterA)
        XCTAssertFalse(tracker.claimWithheldDelivery(queuedPromptID: nil))
        XCTAssertNil(tracker.submittableWithheldDelivery)
    }

    func testManifestCarriesTheClaimedDelivery() throws {
        let id = UUID()
        var manifest = HandoverManifest(chatID: "c", kind: "claude", pid: 7, cols: 100, rows: 30,
                                        sendsInterruptOnStop: true)
        manifest.hasComposerDraft = true
        manifest.composerInsertedText = true
        manifest.composerWithheldDelivery = true
        manifest.composerWithheldQueueID = id.uuidString
        let decoded = try JSONDecoder().decode(HandoverManifest.self, from: JSONEncoder().encode(manifest))
        let restored = AgentTerminalController.withheldDelivery(from: decoded)
        XCTAssertEqual(restored, .init(fromSender: true, queuedPromptID: id, untouched: true))

        var tracker = TerminalComposerDraftTracker()
        tracker.recordDraftAdopted(insertedText: true, withheldDelivery: restored)
        XCTAssertEqual(tracker.submittableWithheldDelivery?.queuedPromptID, id)

        let older = try JSONDecoder().decode(
            HandoverManifest.self,
            from: Data(#"{"chatID":"c","kind":"claude","pid":7,"cols":80,"rows":24,"sendsInterruptOnStop":false,"composerInsertedText":true}"#.utf8))
        XCTAssertNil(AgentTerminalController.withheldDelivery(from: older), "älteres Manifest: nicht abschickbar")
    }
}

final class WithheldDeliverySubmitCheckTests: XCTestCase {
    private let field = InsertedTextScreen.field(text: "[via whisperm8 chats · von Test · 12:00] WM8-Doku prüfen")

    private func check(approval: Bool = false, status: AgentSessionRuntimeStatus? = .idle,
                       withheld: Bool, field: ControllerPromptField?? = nil) -> AgentControlRequestHandler.SubmitDecision {
        AgentControlRequestHandler.submitCheck(
            profile: .claudeCodeChat, status: status, approvalPending: approval,
            userDraft: true, insertedText: true, withheldDelivery: withheld,
            field: field ?? self.field, screenReadable: true)
    }

    func testSubmitSendsAClaimedWithheldDelivery() {
        XCTAssertEqual(field?.hasText, true)
        XCTAssertEqual(check(withheld: true), .allowed)
    }

    func testOtherInsertedTextStaysRefused() {
        XCTAssertEqual(check(withheld: false),
                       .refused(.conflict, AgentControlRequestHandler.submitRefusedInsertedMessage))
    }

    /// Ein getippter Entwurf bleibt gesperrt, auch wenn ein Vermerk daneben stünde.
    func testTypedDraftIsNeverReleased() {
        let decision = AgentControlRequestHandler.submitCheck(
            profile: .claudeCodeChat, status: .idle, approvalPending: false,
            userDraft: true, insertedText: false, withheldDelivery: true,
            field: field, screenReadable: true)
        XCTAssertEqual(decision, .refused(.conflict, AgentControlRequestHandler.submitRefusedTypedMessage))
    }

    func testTheOtherRulesStillApply() {
        guard case .refused(.approvalPending, _) = check(approval: true, withheld: true) else {
            return XCTFail("nie ein Enter in eine Freigabe")
        }
        guard case .refused(.conflict, _) = check(status: .working, withheld: true) else {
            return XCTFail("nur bei ruhendem Chat")
        }
        guard case .refused(.notReady, _) = check(withheld: true, field: .some(nil)) else {
            return XCTFail("ohne sichtbares Feld nichts")
        }
    }

    /// Der vorgemerkte Auftrag ist mit dem Enter von `submit` zugestellt und
    /// kommt beim nächsten Turn-Ende nicht noch einmal. Ein per `dequeue`
    /// stornierter bleibt storniert.
    @MainActor
    func testQueueEntryIsBookedAsDeliveredOnlyWhileOpen() throws {
        let store = AgentPromptQueueStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("withheld-\(UUID().uuidString).json"))
        let session = UUID()
        let open = try store.enqueue(sessionID: session, prompt: "Bitte WM8-Doku prüfen", by: "Test")
        let cancelled = try store.enqueue(sessionID: session, prompt: "Und den Snapshot", by: "Test")
        store.cancel(sessionID: session, ids: [cancelled.id])

        AgentControlRequestHandler.markWithheldQueueEntryDelivered(open.id, sessionID: session, store: store)
        AgentControlRequestHandler.markWithheldQueueEntryDelivered(cancelled.id, sessionID: session, store: store)

        let all = Dictionary(uniqueKeysWithValues: store.all().map { ($0.id, $0.state) })
        XCTAssertEqual(all[open.id], .delivered)
        XCTAssertEqual(all[cancelled.id], .cancelled)
        XCTAssertTrue(store.openPrompts(for: session).isEmpty)
    }

    func testWithheldMessagesNameSubmit() {
        XCTAssertTrue(AgentControlRequestHandler.enterWithheldMessage.contains("chats submit"))
        XCTAssertTrue(AgentPromptQueueDelivery.withheldError.contains("chats submit"))
    }
}

/// WM8-123, Punkt 4: Der Kontowechsel nach dem Turn liest das Feld wie die
/// Warteschlange. Ein wieder gelöschtes Diktat hält ihn nicht mehr bis zum
/// nächsten Enter auf; sichtbarer Text hält ihn weiter.
final class AccountSwitchScreenDraftTests: XCTestCase {
    func testVisiblyEmptyFieldReleasesTheSwitch() {
        XCTAssertFalse(ComposerDraftOnScreen.mayHaveUnsentInput(estimate: true, field: .empty))
    }

    func testVisibleTextHoldsTheSwitch() {
        XCTAssertTrue(ComposerDraftOnScreen.mayHaveUnsentInput(estimate: false, field: .hasText))
    }

    func testUnreadableFieldKeepsTheEstimate() {
        XCTAssertTrue(ComposerDraftOnScreen.mayHaveUnsentInput(estimate: true, field: .unknown))
        XCTAssertFalse(ComposerDraftOnScreen.mayHaveUnsentInput(estimate: false, field: .unknown))
    }

    /// Der Fall aus dem Ticket: Diktat ohne Senden, mit der Rücktaste gelöscht,
    /// Terminal unten. Die Schätzung hält den Text weiter für da.
    func testDeletedDictationNoLongerHoldsTheSwitch() {
        var tracker = TerminalComposerDraftTracker()
        tracker.recordTextInserted()
        tracker.recordTerminalKey(keyCode: 51, modifiers: [], status: .idle, restoresPromptOnInterrupt: true, now: Date())
        XCTAssertTrue(tracker.mayHaveUnsentInput)
        let emptyAtBottom = BoardChatFieldVisibility(
            reading: ComposerFieldReading(field: InsertedTextScreen.field(text: ""), atBottom: true),
            profile: .claudeCodeChat, clearsBeforeSubmit: tracker.shouldClearBeforeSubmit)
        XCTAssertEqual(emptyAtBottom, .empty)
        let draft = ComposerDraftOnScreen.mayHaveUnsentInput(estimate: tracker.mayHaveUnsentInput, field: emptyAtBottom)
        XCTAssertNil(AccountSwitchPlanner.waitReason(status: .idle, mayHaveUnsentInput: draft))

        // Hochgescrollt zählt ein leeres Feld nicht: Dann bleibt es beim Warten.
        let emptyScrolledBack = BoardChatFieldVisibility(
            reading: ComposerFieldReading(field: InsertedTextScreen.field(text: ""), atBottom: false),
            profile: .claudeCodeChat, clearsBeforeSubmit: false)
        XCTAssertEqual(AccountSwitchPlanner.waitReason(
            status: .idle,
            mayHaveUnsentInput: ComposerDraftOnScreen.mayHaveUnsentInput(estimate: true, field: emptyScrolledBack)),
            .unsentInput)
    }

    func testScreenIsOnlyReadWhileTheChatRests() {
        XCTAssertTrue(ComposerDraftOnScreen.readsScreen(status: .idle))
        XCTAssertFalse(ComposerDraftOnScreen.readsScreen(status: .working))
        XCTAssertFalse(ComposerDraftOnScreen.readsScreen(status: .awaitingInput))
        XCTAssertFalse(ComposerDraftOnScreen.readsScreen(status: nil))
    }
}
