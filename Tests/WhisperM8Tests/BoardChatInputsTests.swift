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
    private var fieldHasText = false
    private var field: BoardChatFieldVisibility = .unknown
    private var clock = Date(timeIntervalSince1970: 1_794_700_000)
    private var resets: Int? = 0

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
        fieldHasText = false
        inputs.hasUnsentInput = { [unowned self] _ in fieldHasText }
        field = .unknown
        inputs.fieldVisibility = { [unowned self] _ in field }
        inputs.now = { [unowned self] in clock }
        resets = 0
        inputs.fieldResets = { [unowned self] _ in resets }
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

    // MARK: Triage sammeln (Teil d)

    /// Eine Sekunde nach dem letzten Klick entscheiden (nicht als Doppelklick).
    @discardableResult
    private func decideLater(_ decision: TriageDecision, in windowID: UUID) -> Bool {
        clock = clock.addingTimeInterval(1)
        return inputs.decide(decision, in: windowID)
    }

    func testVisibleFieldDecidesWhetherTheOrderIsStillOpen() {
        inputs.register(windowID: window, sessionID: jarvis, name: "Jarvis")
        decideLater(.accept, in: window)
        fieldHasText = true
        field = .empty                                     // sichtbar leer: abgeschickt, trotz Schätzung
        shown[window] = ticket86
        decideLater(.later, in: window)
        XCTAssertTrue(inserted.last!.0.hasPrefix(String(localized: "Triage in WM8, please carry out:")))
        fieldHasText = false
        field = .hasText                                   // sichtbarer Text: Auftrag noch offen
        shown[window] = ticket81
        decideLater(.accept, in: window)
        XCTAssertTrue(inserted.last!.0.hasPrefix("\n- WM8-81"))
    }

    func testAnotherBoardChatStartsANewOrderAndDropsTheMarks() {
        let pia = UUID()
        inputs.register(windowID: window, sessionID: jarvis, name: "Jarvis")
        decideLater(.accept, in: window)
        fieldHasText = true
        inputs.register(windowID: window, sessionID: pia, name: "Pia")
        XCTAssertNil(inputs.triageDecision(for: "WM8-81", in: window), "Marken gehören zum alten Chat")
        shown[window] = ticket86
        decideLater(.later, in: window)
        XCTAssertEqual(inserted.last?.1, pia)
        XCTAssertTrue(inserted.last!.0.contains(String(localized: "Triage in WM8, please carry out:")), "neuer Auftrag mit Überschrift")
        XCTAssertNil(inputs.triageDecision(for: "WM8-81", in: window))
        XCTAssertEqual(inputs.triageDecision(for: "WM8-86", in: window), .later)
    }

    func testDoubleClickDoesNotDecideTheNextTicket() {
        inputs.register(windowID: window, sessionID: jarvis, name: "Jarvis")
        XCTAssertTrue(decideLater(.accept, in: window))
        shown[window] = ticket86                           // Triage ist weitergesprungen
        clock = clock.addingTimeInterval(0.2)
        XCTAssertFalse(inputs.decide(.accept, in: window))
        XCTAssertNil(inputs.triageDecision(for: "WM8-86", in: window))
        XCTAssertEqual(inserted.count, 1)
    }

    func testReferenceAndHandOffStartOnANewLineAfterTriageLines() throws {
        inputs.register(windowID: window, sessionID: jarvis, name: "Jarvis")
        decideLater(.accept, in: window)
        shown[window] = ticket86                           // nächstes Ticket, sein Bezug ist frei
        let reference = try XCTUnwrap(inputs.referenceForDictation(to: jarvis))
        XCTAssertTrue(reference.prefix.hasPrefix(String(localized: "Re:")), "der Umbruch kommt beim Ausliefern")
        XCTAssertEqual(inputs.leadForDictation(to: jarvis), "\n", "nicht an „annehmen“ kleben")
        XCTAssertTrue(inputs.handOff(in: window))
        XCTAssertTrue(inserted.last!.0.hasPrefix("\nWM8-86"))
    }

    /// Fenster zu: Der Auftrag geht mit.
    func testClosingTheWindowClearsTheOrder() {
        inputs.register(windowID: window, sessionID: jarvis, name: "Jarvis")
        decideLater(.accept, in: window)
        inputs.unregister(windowID: window)
        XCTAssertNil(inputs.triageBatches[window])
    }

    /// Prüfpunkt 1 (WM8-124): Tickets kurz zu, Spalte zu, Chat kurz woanders.
    /// Die Zeilen stehen weiter im Feld; der nächste Klick setzt den Auftrag fort.
    func testHidingTheColumnKeepsTheOrder() {
        let firstView = UUID()
        inputs.register(windowID: window, sessionID: jarvis, name: "Jarvis", token: firstView)
        decideLater(.accept, in: window)
        fieldHasText = true
        inputs.unregister(windowID: window, token: firstView)
        XCTAssertNil(inputs.triageDecision(for: "WM8-81", in: window), "ohne Spalte keine Marken")
        inputs.register(windowID: window, sessionID: jarvis, name: "Jarvis", token: UUID())
        XCTAssertEqual(inputs.triageDecision(for: "WM8-81", in: window), .accept, "Marke wieder da")
        shown[window] = ticket86
        decideLater(.later, in: window)
        XCTAssertTrue(inserted.last!.0.hasPrefix("\n- WM8-86"), "keine zweite Überschrift")
    }

    /// Prüfpunkt 2 (WM8-124): Abgeschickt, neu getippt, dann geklickt: neuer
    /// Auftrag mit Überschrift, ohne „(statt: …)“ und ohne alte Marken.
    func testSubmittingEndsTheOrderEvenAfterNewTyping() {
        inputs.register(windowID: window, sessionID: jarvis, name: "Jarvis")
        decideLater(.accept, in: window)
        resets = 1                                         // Enter: abgeschickt
        fieldHasText = true                                // und schon wieder getippt
        field = .hasText
        decideLater(.decline, in: window)                  // dasselbe Ticket, andere Entscheidung
        let last = inserted.last!.0
        XCTAssertTrue(last.hasPrefix("\n" + String(localized: "Triage in WM8, please carry out:")), "eigene Zeile, neue Überschrift")
        XCTAssertFalse(last.contains(String(localized: "(instead of: \(TriageDecision.accept.instruction))")))
        XCTAssertEqual(inputs.triageDecision(for: "WM8-81", in: window), .decline)
    }

    /// Ohne Terminal (kein Zähler) gilt wie bisher nur das Feld.
    func testWithoutCounterTheFieldDecides() {
        resets = nil
        inputs.register(windowID: window, sessionID: jarvis, name: "Jarvis")
        decideLater(.accept, in: window)
        field = .hasText
        shown[window] = ticket86
        decideLater(.later, in: window)
        XCTAssertTrue(inserted.last!.0.hasPrefix("\n- WM8-86"))
    }

    /// Prüfpunkt 3 (WM8-124): Der Umbruch hängt nicht am Bezug und wird beim
    /// Ausliefern bestimmt.
    func testLeadForDictationIsDecidedOnDeliveryWithoutReference() {
        inputs.register(windowID: window, sessionID: jarvis, name: "Jarvis")
        shown[window] = nil                                // Board, kein Bezug
        XCTAssertNil(inputs.referenceForDictation(to: jarvis))
        XCTAssertEqual(inputs.leadForDictation(to: jarvis), "")
        fieldHasText = true                                // inzwischen getippt
        XCTAssertEqual(inputs.leadForDictation(to: jarvis), "\n")
        field = .empty
        XCTAssertEqual(inputs.leadForDictation(to: jarvis), "")
        XCTAssertEqual(inputs.leadForDictation(to: UUID()), "", "kein Board-Chat")
    }

    func testDecisionsCollectAsOneOrderWithHeaderAndNeverSend() {
        inputs.register(windowID: window, sessionID: jarvis, name: "Jarvis")
        XCTAssertTrue(decideLater(.accept, in: window))
        fieldHasText = true                                // die erste Zeile steht im Feld
        shown[window] = ticket86
        XCTAssertTrue(decideLater(.later, in: window))
        let header = String(localized: "Triage in WM8, please carry out:")
        XCTAssertEqual(inserted.map(\.0), [
            header + "\n- WM8-81 „Ticket-Board: Board und Backlog lesen“ https://linear.app/whisperm8/issue/WM8-81: "
                + TriageDecision.accept.instruction,
            "\n- WM8-86 „Entscheidung festhalten“ https://linear.app/whisperm8/issue/WM8-86: " + TriageDecision.later.instruction,
        ])
        XCTAssertFalse(inserted.map(\.0).joined().contains("\r"), "nie ein Enter")
        XCTAssertEqual(inputs.triageDecision(for: "WM8-81", in: window), .accept)
        XCTAssertEqual(inputs.triageDecision(for: "WM8-86", in: window), .later)
    }

    func testChangingADecisionSaysWhatItReplaces() {
        inputs.register(windowID: window, sessionID: jarvis, name: "Jarvis")
        decideLater(.accept, in: window)
        fieldHasText = true
        decideLater(.decline, in: window)
        XCTAssertEqual(inserted.last?.0, "\n- WM8-81 „Ticket-Board: Board und Backlog lesen“ https://linear.app/whisperm8/issue/WM8-81: "
            + TriageDecision.decline.instruction + " " + String(localized: "(instead of: \(TriageDecision.accept.instruction))"))
        XCTAssertEqual(inputs.triageDecision(for: "WM8-81", in: window), .decline)
    }

    func testAfterSendingANewOrderStartsWithItsHeader() {
        inputs.register(windowID: window, sessionID: jarvis, name: "Jarvis")
        decideLater(.accept, in: window)
        fieldHasText = false                               // Giuliano hat abgeschickt
        shown[window] = ticket86
        decideLater(.duplicate, in: window)
        XCTAssertTrue(inserted.last!.0.hasPrefix(String(localized: "Triage in WM8, please carry out:")))
        XCTAssertNil(inputs.triageDecision(for: "WM8-81", in: window), "Markierungen des alten Auftrags sind weg")
        XCTAssertEqual(inputs.triageDecision(for: "WM8-86", in: window), .duplicate)
    }

    func testOwnTextInTheFieldPutsTheOrderOnANewLine() {
        inputs.register(windowID: window, sessionID: jarvis, name: "Jarvis")
        fieldHasText = true
        decideLater(.askBack, in: window)
        XCTAssertTrue(inserted[0].0.hasPrefix("\n" + String(localized: "Triage in WM8, please carry out:")))
    }

    func testNoDecisionIntoAnOpenQuestionAndNoMark() {
        inputs.register(windowID: window, sessionID: jarvis, name: "Jarvis")
        state = .awaitingInput
        XCTAssertFalse(decideLater(.accept, in: window))
        approval = true
        state = .ready
        XCTAssertFalse(decideLater(.accept, in: window))
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertNil(inputs.triageDecision(for: "WM8-81", in: window))
        XCTAssertEqual(beeps, 2)
    }

    // MARK: Texte

    func testTicketLineHasNoControlCharactersAndNoDescription() {
        let hostile = BoardChatTicket(key: "WM8-9", title: "Titel\u{1B}[201~\nmit Umbruch\u{202E}", url: nil)
        XCTAssertEqual(BoardChatText.ticketLine(hostile), "WM8-9 „Titel [201~ mit Umbruch“")
    }

    func testVeryLongTitlesAreShortened() {
        let long = BoardChatTicket(key: "WM8-1", title: String(repeating: "a", count: 500), url: nil)
        XCTAssertEqual(BoardChatText.ticketLine(long).count, "WM8-1 „“".count + BoardChatText.maximumTitleLength)
        XCTAssertTrue(BoardChatText.ticketLine(long).hasSuffix("…“"))
    }

    func testDictationLabelNamesTheBoardChat() {
        inputs.register(windowID: window, sessionID: jarvis, name: "Jarvis")
        XCTAssertEqual(inputs.dictationLabel(for: .boardChat(sessionID: jarvis)), "Jarvis")
        XCTAssertNil(inputs.dictationLabel(for: .frontApp))
        XCTAssertNil(inputs.dictationLabel(for: .agentChat(sessionID: jarvis)))
    }

    func testCallName() {
        XCTAssertEqual(BoardChatText.callName("Jarvis: Supervisor WhisperM8"), "Jarvis")
        XCTAssertEqual(BoardChatText.callName("Pia · Produkt WM8"), "Pia")
        XCTAssertEqual(BoardChatText.callName("Jarvis"), "Jarvis")
        XCTAssertEqual(BoardChatText.callName("Ein sehr langer Titel ohne Trenner und ohne Ende"), "Ein sehr langer Titel o…")
    }
}
