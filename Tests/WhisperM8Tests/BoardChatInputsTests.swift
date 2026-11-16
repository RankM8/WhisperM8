import Foundation
@testable import WhisperM8
import XCTest

/// Eingaben an den Board-Chat (WM8-113, Teil b): Nichts geht an einen Chat,
/// den Giuliano nicht sieht, nichts in eine offene Frage oder Freigabe, und
/// die App schickt nie selbst ab.
@MainActor
final class BoardChatInputsTests: XCTestCase {
    private let window = UUID()
    private let otherWindow = UUID()
    private let jarvis = UUID()
    private var inputs: BoardChatInputs!
    private var keyWindow: UUID?
    private var state: DictationChatState = .ready
    private var approval = false
    private var inserted: [(String, UUID)] = []
    private var beeps = 0
    private var shown: [UUID: BoardChatTicket] = [:]

    private let ticket81 = BoardChatTicket(key: "WM8-81", title: "Ticket-Board: Board und Backlog lesen",
                                           url: "https://linear.app/whisperm8/issue/WM8-81")
    private let ticket86 = BoardChatTicket(key: "WM8-86", title: "Entscheidung festhalten",
                                           url: "https://linear.app/whisperm8/issue/WM8-86")

    override func setUp() async throws {
        inputs = BoardChatInputs()
        keyWindow = window
        state = .ready
        approval = false
        inserted = []
        beeps = 0
        shown = [window: ticket81]
        inputs.keyWindowID = { [unowned self] in keyWindow }
        inputs.shownTicket = { [unowned self] in shown[$0] }
        inputs.ticketForKey = { [unowned self] _, key in [ticket81, ticket86].first { $0.key == key } }
        inputs.chatState = { [unowned self] _ in state }
        inputs.approvalPending = { [unowned self] _ in approval }
        inputs.insert = { [unowned self] text, id in inserted.append((text, id)); return true }
        inputs.refuseSound = { [unowned self] in beeps += 1 }
        inputs.noticeSeconds = 60
    }

    // MARK: Wer ist Ziel

    func testDictationTargetIsOnlyTheVisibleBoardChatOfTheWindowInFront() {
        XCTAssertNil(inputs.dictationTarget(), "ohne angemeldeten Board-Chat")
        inputs.register(windowID: otherWindow, sessionID: jarvis, name: "Jarvis")
        XCTAssertNil(inputs.dictationTarget(), "Board-Chat eines Fensters, das nicht vorn ist")
        inputs.register(windowID: window, sessionID: jarvis, name: "Jarvis")
        XCTAssertEqual(inputs.dictationTarget(), jarvis)
        keyWindow = nil
        XCTAssertNil(inputs.dictationTarget(), "kein Agent-Chats-Fenster vorn")
    }

    func testOnlyTheRegisteringViewUnregisters() {
        let oldView = UUID(), newView = UUID()
        inputs.register(windowID: window, sessionID: jarvis, name: "Jarvis", token: oldView)
        inputs.register(windowID: window, sessionID: jarvis, name: "Jarvis", token: newView)
        inputs.unregister(windowID: window, token: oldView)   // verspätetes Verschwinden der alten Ansicht
        XCTAssertEqual(inputs.boardChat(in: window)?.sessionID, jarvis)
        inputs.unregister(windowID: window, token: newView)
        XCTAssertNil(inputs.boardChat(in: window))
    }

    // MARK: → Jarvis

    func testHandOffPutsNumberTitleAndLinkIntoTheFieldWithoutSending() {
        inputs.register(windowID: window, sessionID: jarvis, name: "Jarvis")
        XCTAssertTrue(inputs.handOff(in: window))
        XCTAssertEqual(inserted.map(\.0), ["WM8-81 „Ticket-Board: Board und Backlog lesen“ https://linear.app/whisperm8/issue/WM8-81 "])
        XCTAssertEqual(inserted.map(\.1), [jarvis])
        XCTAssertFalse(inserted[0].0.contains("\r"), "kein Enter")
        XCTAssertNil(inputs.reference(in: window), "Das Ticket steht schon im Feld, kein doppelter Bezug")
    }

    func testHandOffOfAnotherTicketByKey() {
        inputs.register(windowID: window, sessionID: jarvis, name: "Jarvis")
        XCTAssertTrue(inputs.handOff(key: "WM8-86", in: window))
        XCTAssertTrue(inserted[0].0.hasPrefix("WM8-86 „Entscheidung festhalten“"))
    }

    func testNothingGoesIntoAnOpenQuestionOrApproval() {
        inputs.register(windowID: window, sessionID: jarvis, name: "Jarvis")
        for (chatState, pending) in [(DictationChatState.awaitingInput, false), (.questionAcceptsText, false), (.ready, true),
                                     (.starting, false), (.usageLimited, false), (.notRunning, false)] {
            state = chatState
            approval = pending
            XCTAssertFalse(inputs.handOff(in: window), "\(chatState) approval=\(pending)")
        }
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertEqual(beeps, 6)
        XCTAssertNotNil(inputs.notices[window])
    }

    func testHandOffWithoutVisibleBoardChatDoesNothing() {
        XCTAssertFalse(inputs.handOff(in: window))
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertEqual(beeps, 1)
    }

    func testRefusalMessageNamesTheChat() {
        XCTAssertEqual(BoardChatInputRules.message(.awaitingInput, chatName: "Jarvis"),
                       String(localized: "Jarvis is waiting for your answer. Nothing was added."))
    }

    // MARK: Bezug

    func testReferenceFollowsTheTriageAndCanBeDismissedPerTicket() {
        XCTAssertNil(inputs.reference(in: window), "ohne sichtbaren Board-Chat kein Bezug")
        inputs.register(windowID: window, sessionID: jarvis, name: "Jarvis")
        XCTAssertEqual(inputs.reference(in: window), ticket81)
        inputs.dismissReference(in: window)
        XCTAssertNil(inputs.reference(in: window))
        shown[window] = ticket86                           // J: nächstes Ticket
        XCTAssertEqual(inputs.reference(in: window), ticket86)
        shown[window] = nil                                // zurück zum Board
        XCTAssertNil(inputs.reference(in: window))
    }

    func testDictationReferenceIsUsedOnceAfterCommit() throws {
        inputs.register(windowID: window, sessionID: jarvis, name: "Jarvis")
        XCTAssertNil(inputs.referenceForDictation(to: UUID()), "anderer Chat bekommt keinen Bezug")
        let reference = try XCTUnwrap(inputs.referenceForDictation(to: jarvis))
        XCTAssertEqual(reference.prefix, String(localized: "Re:") + " WM8-81 „Ticket-Board: Board und Backlog lesen“ https://linear.app/whisperm8/issue/WM8-81\n")
        XCTAssertNotNil(inputs.referenceForDictation(to: jarvis), "erst nach dem Schreiben verbraucht")
        reference.commit()
        XCTAssertNil(inputs.referenceForDictation(to: jarvis))
    }

    // MARK: Texte

    func testTicketLineHasNoControlCharactersAndNoDescription() {
        let hostile = BoardChatTicket(key: "WM8-9", title: "Titel\u{1B}[201~\nmit Umbruch\u{202E}", url: nil)
        XCTAssertEqual(BoardChatText.ticketLine(hostile), "WM8-9 „Titel [201~ mit Umbruch“")
    }

    func testCallName() {
        XCTAssertEqual(BoardChatText.callName("Jarvis: Supervisor WhisperM8"), "Jarvis")
        XCTAssertEqual(BoardChatText.callName("Pia · Produkt WM8"), "Pia")
        XCTAssertEqual(BoardChatText.callName("Jarvis"), "Jarvis")
        XCTAssertEqual(BoardChatText.callName("Ein sehr langer Titel ohne Trenner und ohne Ende"), "Ein sehr langer Titel o…")
    }
}
