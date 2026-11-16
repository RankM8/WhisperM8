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

    private let withheldAt = Date(timeIntervalSince1970: 1_794_750_000)
    private var marked: String { "[via whisperm8 chats · von Warteschlange · Ben · 14:02]\nweiter" }

    func testAlreadySentOnlyForTheExactTextWrittenAfterwards() {
        let after = withheldAt.addingTimeInterval(20)
        XCTAssertTrue(AgentPromptQueueDelivery.alreadySent(
            withheldText: marked, withheldAt: withheldAt, lastUser: (marked, after)))
        // Giuliano hat vor dem Enter etwas angehängt: zählt.
        XCTAssertTrue(AgentPromptQueueDelivery.alreadySent(
            withheldText: marked, withheldAt: withheldAt, lastUser: (marked + " und dann WM8-Doku", after)))
        // Zeilenenden aus dem Transcript.
        XCTAssertTrue(AgentPromptQueueDelivery.alreadySent(
            withheldText: marked, withheldAt: withheldAt,
            lastUser: (marked.replacingOccurrences(of: "\n", with: "\r\n"), after)))
    }

    /// Auflage der Prüferin (a): Kurzer Auftrag („weiter“), die letzte
    /// Nachricht war eine andere zugestellte Meldung, in der das Wort vorkommt.
    func testShortPromptInsideAnotherMessageIsNotSent() {
        let other = "[via whisperm8 chats · von Jarvis · 14:03]\nBitte weiter mit WM8-122, dann melden."
        XCTAssertFalse(AgentPromptQueueDelivery.alreadySent(
            withheldText: marked, withheldAt: withheldAt, lastUser: (other, withheldAt.addingTimeInterval(30))))
    }

    /// Auflage der Prüferin (b): Derselbe Text kam früher regulär an und ist
    /// noch die letzte Nachricht; der zurückgehaltene ging nie raus.
    func testEarlierIdenticalMessageIsNotSent() {
        XCTAssertFalse(AgentPromptQueueDelivery.alreadySent(
            withheldText: marked, withheldAt: withheldAt, lastUser: (marked, withheldAt.addingTimeInterval(-60))))
        XCTAssertFalse(AgentPromptQueueDelivery.alreadySent(
            withheldText: marked, withheldAt: withheldAt, lastUser: (marked, nil)), "ohne Zeitstempel: nicht gesendet")
    }

    func testWithoutRememberedTextNothingCountsAsSent() {
        let after = withheldAt.addingTimeInterval(20)
        XCTAssertFalse(AgentPromptQueueDelivery.alreadySent(withheldText: nil, withheldAt: withheldAt, lastUser: (marked, after)))
        XCTAssertFalse(AgentPromptQueueDelivery.alreadySent(withheldText: marked, withheldAt: nil, lastUser: (marked, after)))
        XCTAssertFalse(AgentPromptQueueDelivery.alreadySent(withheldText: marked, withheldAt: withheldAt, lastUser: nil))
        XCTAssertFalse(AgentPromptQueueDelivery.alreadySent(withheldText: "weiter", withheldAt: withheldAt,
                                                            lastUser: ("weiter", after)), "ohne Marker-Zeile nie")
    }

    func testLastUserMessageSkipsToolResults() {
        let at = withheldAt.addingTimeInterval(5)
        let messages = [
            AgentChatMessage(id: UUID(), role: .user, timestamp: at, blocks: [.text(marked)]),
            AgentChatMessage(id: UUID(), role: .assistant, timestamp: nil, blocks: [.toolUse(name: "Bash", input: "ls")]),
            AgentChatMessage(id: UUID(), role: .user, timestamp: nil, blocks: [.toolResult(content: "ok", isError: false)]),
        ]
        let last = AgentPromptQueueDelivery.lastUserMessage(in: messages)
        XCTAssertEqual(last?.text, marked)
        XCTAssertEqual(last?.at, at)
        XCTAssertNil(AgentPromptQueueDelivery.lastUserMessage(in: []))
    }

    func testQueueFileKeepsTheWithheldMarkAndOldFilesStillLoad() throws {
        let url = tempFile()
        let store = AgentPromptQueueStore(fileURL: url)
        let entry = try store.enqueue(sessionID: UUID(), prompt: "Bitte WM8-Doku prüfen", by: "Test")
        store.markEnterWithheld(id: entry.id, error: AgentPromptQueueDelivery.withheldError, text: marked, at: withheldAt)
        let stored = try XCTUnwrap(store.all().first)
        XCTAssertTrue(stored.enterWithheld)
        XCTAssertEqual(stored.withheldText, marked)
        XCTAssertEqual(stored.withheldAt, withheldAt)
        let reloaded = AgentPromptQueueStore(fileURL: url)
        XCTAssertEqual(reloaded.all().first?.withheldText, marked, "übersteht einen Neustart")
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
