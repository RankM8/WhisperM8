import AppKit
import XCTest
@testable import WhisperM8

/// Ränder zu WM8-123 (Sendeweg) aus dem Gegenlesen von Paket C: doppeltes
/// Enter im Nachlauf des Freigabe-Status, Lösch-Kürzel im Nachlauf, Enter in
/// einer Vervollständigung.
final class WithheldDeliveryEdgeTests: XCTestCase {
    private let enter: UInt16 = 36
    private let letterA: UInt16 = 0
    private let controlC: UInt16 = 8

    private func key(_ tracker: inout TerminalComposerDraftTracker, _ code: UInt16,
                     _ modifiers: NSEvent.ModifierFlags = [], status: AgentSessionRuntimeStatus? = .idle) {
        tracker.recordTerminalKey(keyCode: code, modifiers: modifiers, status: status,
                                  restoresPromptOnInterrupt: true, now: Date())
    }

    private func withheld(_ id: UUID?) -> TerminalComposerDraftTracker {
        var tracker = TerminalComposerDraftTracker()
        tracker.recordSubmitted(programmaticAt: Date())
        tracker.recordDeliveryWithheld()
        XCTAssertTrue(tracker.claimWithheldDelivery(queuedPromptID: id))
        return tracker
    }

    // MARK: Lösch-Kürzel im Nachlauf

    func testControlEditingKeysAreNoDialogAnswer() {
        for code: UInt16 in [13, 32, 40, 4] {   // Ctrl+W, Ctrl+U, Ctrl+K, Ctrl+H
            var tracker = withheld(UUID())
            key(&tracker, code, .control, status: .awaitingInput)
            XCTAssertNil(tracker.submittableWithheldDelivery, "Ctrl-Taste \(code) löscht Text")
        }
        var controlC = withheld(UUID())
        key(&controlC, self.controlC, .control, status: .awaitingInput)
        XCTAssertNotNil(controlC.submittableWithheldDelivery, "Ctrl+C im Dialog schreibt nichts ins Feld")
    }

    // MARK: Enter in einer Vervollständigung

    /// Blieb der Text nach dem Enter stehen, gilt derselbe Vermerk wieder;
    /// das nächste echte Enter verbucht. Ein unberührter bleibt für `submit`
    /// abschickbar (liegengebliebenes Enter).
    func testSubmitThatStayedInFieldRestoresTheSameMark() {
        let id = UUID()
        var untouched = withheld(id)
        key(&untouched, enter)
        XCTAssertEqual(untouched.takeSubmittedWithheldQueueID(), id)
        untouched.recordSubmitStayedInField(queuedPromptID: id)
        XCTAssertTrue(untouched.mayHaveUnsentInput, "Text steht noch: Warteschlange hält an")
        XCTAssertEqual(untouched.submittableWithheldDelivery?.queuedPromptID, id)

        var completion = withheld(id)
        key(&completion, letterA)        // etwa „@Doku“ getippt
        key(&completion, enter)          // Vervollständigung gewählt
        XCTAssertEqual(completion.takeSubmittedWithheldQueueID(), id)
        completion.recordSubmitStayedInField(queuedPromptID: id)
        XCTAssertNil(completion.submittableWithheldDelivery, "bearbeitet: submit schickt nicht ab")
        XCTAssertEqual(completion.withheldDelivery?.queuedPromptID, id)
        key(&completion, enter)          // jetzt wirklich abgeschickt
        XCTAssertEqual(completion.takeSubmittedWithheldQueueID(), id)
    }

    func testCompletionIsOnlyTextWithoutATurn() {
        let text = InsertedTextScreen.field(text: "Bitte @WhisperM8/Views")
        let empty = InsertedTextScreen.field(text: "")
        XCTAssertTrue(AgentTerminalController.submitLandedInCompletion(status: .idle, field: text))
        XCTAssertFalse(AgentTerminalController.submitLandedInCompletion(status: .working, field: text), "Turn begann: raus")
        XCTAssertFalse(AgentTerminalController.submitLandedInCompletion(status: .idle, field: empty))
        XCTAssertFalse(AgentTerminalController.submitLandedInCompletion(status: .idle, field: nil), "nicht ablesbar: verbuchen")
    }

    // MARK: Doppeltes Enter im Nachlauf: Blick ins Transcript

    func testAlreadySentNeedsMarkerAndWholePrompt() {
        let prompt = "Bitte die WM8-Doku zum Snapshot ergänzen."
        let sent = "[via whisperm8 chats · von Warteschlange · Ben · 14:02]\n" + prompt
        XCTAssertTrue(AgentPromptQueueDelivery.alreadySent(prompt: prompt, lastUserText: sent))
        XCTAssertFalse(AgentPromptQueueDelivery.alreadySent(prompt: prompt, lastUserText: prompt),
                       "ohne Marker schrieb der User selbst")
        XCTAssertFalse(AgentPromptQueueDelivery.alreadySent(prompt: prompt, lastUserText: "[via whisperm8 chats · von Ben · 14:02]\netwas anderes"))
        XCTAssertFalse(AgentPromptQueueDelivery.alreadySent(prompt: prompt, lastUserText: nil))
        XCTAssertFalse(AgentPromptQueueDelivery.alreadySent(prompt: "  ", lastUserText: sent))
    }

    func testLastUserTextSkipsToolResults() {
        let messages = [
            AgentChatMessage(id: UUID(), role: .user, timestamp: nil, blocks: [.text("[via whisperm8 chats · von Ben · 14:02]\nAuftrag")]),
            AgentChatMessage(id: UUID(), role: .assistant, timestamp: nil, blocks: [.toolUse(name: "Bash", input: "ls")]),
            AgentChatMessage(id: UUID(), role: .user, timestamp: nil, blocks: [.toolResult(content: "ok", isError: false)]),
        ]
        XCTAssertEqual(AgentPromptQueueDelivery.lastUserText(in: messages), "[via whisperm8 chats · von Ben · 14:02]\nAuftrag")
        XCTAssertNil(AgentPromptQueueDelivery.lastUserText(in: []))
    }

    func testQueueFileKeepsTheWithheldMarkAndOldFilesStillLoad() throws {
        let store = AgentPromptQueueStore(fileURL: tempFile())
        let entry = try store.enqueue(sessionID: UUID(), prompt: "Bitte WM8-Doku prüfen", by: "Test")
        store.markEnterWithheld(id: entry.id, error: AgentPromptQueueDelivery.withheldError)
        let stored = try XCTUnwrap(store.all().first)
        XCTAssertTrue(stored.enterWithheld)
        XCTAssertEqual(stored.state, .pending)

        let old = try JSONDecoder().decode(QueuedPrompt.self, from: Data(
            #"{"sessionID":"\#(UUID().uuidString)","prompt":"x","enqueuedAt":0,"enqueuedBy":"Test"}"#.utf8))
        XCTAssertFalse(old.enterWithheld)
    }

    /// Verbucht nur, solange er offen ist; ein `dequeue` bleibt ein Storno.
    @MainActor
    func testAlreadySentIsBookedOnlyWhileOpen() throws {
        let store = AgentPromptQueueStore(fileURL: tempFile())
        let delivery = AgentPromptQueueDelivery(store: store, settleDelay: 0, notices: QueueHoldNotices())
        let session = UUID()
        let open = try store.enqueue(sessionID: session, prompt: "Auftrag eins", by: "Test")
        let cancelled = try store.enqueue(sessionID: session, prompt: "Auftrag zwei", by: "Test")
        store.cancel(sessionID: session, ids: [cancelled.id])
        XCTAssertTrue(delivery.markAlreadySent(open.id, sessionID: session))
        XCTAssertFalse(delivery.markAlreadySent(cancelled.id, sessionID: session))
        let states = Dictionary(uniqueKeysWithValues: store.all().map { ($0.id, $0.state) })
        XCTAssertEqual(states[open.id], .delivered)
        XCTAssertEqual(states[cancelled.id], .cancelled)
    }

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("withheld-edge-\(UUID().uuidString).json")
    }
}
