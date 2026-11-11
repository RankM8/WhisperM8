import Foundation
import XCTest
@testable import WhisperM8

/// Jede Regel der Diktat-Zustellung einzeln: vorderes Programm unverändert,
/// Chat nur, wenn er bereit ist, sonst Zwischenablage mit Grund.
final class DictationDeliveryRouterTests: XCTestCase {
    private let sessionID = UUID()

    private func decide(
        _ delivery: DictationDelivery,
        text: String = "Hallo",
        state: DictationChatState = .ready
    ) -> DictationDeliveryDecision {
        DictationDeliveryRouter.decide(delivery: delivery, text: text, chatState: { _ in state })
    }

    private func chat(submit: Bool = false) -> DictationDelivery {
        DictationDelivery(target: .agentChat(sessionID: sessionID), submit: submit)
    }

    func testDefaultIsFrontAppWithoutSubmit() {
        XCTAssertEqual(DictationDelivery.frontApp.target, .frontApp)
        XCTAssertFalse(DictationDelivery.frontApp.submit)
        XCTAssertEqual(DictationDelivery(), .frontApp)
    }

    func testFrontAppAlwaysStaysFrontAppAndNeverAsksForChatState() {
        var asked = false
        for text in ["Hallo", "", "   \n"] {
            let decision = DictationDeliveryRouter.decide(delivery: .frontApp, text: text) { _ in
                asked = true
                return .notRunning
            }
            XCTAssertEqual(decision, .frontApp, "Text: \(text.debugDescription)")
        }
        // Auch ein gesetztes `submit` ändert am vorderen Programm nichts.
        XCTAssertEqual(decide(DictationDelivery(target: .frontApp, submit: true)), .frontApp)
        XCTAssertFalse(asked)
    }

    func testEmptyOrWhitespaceTextForChatDeliversNothing() {
        XCTAssertEqual(decide(chat(), text: ""), .nothing)
        XCTAssertEqual(decide(chat(submit: true), text: "  \n\t "), .nothing)
    }

    func testEmptyTextWinsOverChatState() {
        XCTAssertEqual(decide(chat(), text: " ", state: .notRunning), .nothing)
    }

    func testReadyChatWritesWithoutSubmit() {
        XCTAssertEqual(decide(chat(), state: .ready), .writeToChat(sessionID: sessionID, submit: false))
    }

    func testReadyChatWritesWithSubmit() {
        XCTAssertEqual(decide(chat(submit: true), state: .ready), .writeToChat(sessionID: sessionID, submit: true))
    }

    func testAwaitingInputKeepsTextOnClipboard() {
        XCTAssertEqual(decide(chat(), state: .awaitingInput), .clipboardOnly(.decisionPending))
        XCTAssertEqual(decide(chat(submit: true), state: .awaitingInput), .clipboardOnly(.decisionPending))
    }

    func testStartingChatKeepsTextOnClipboard() {
        XCTAssertEqual(decide(chat(), state: .starting), .clipboardOnly(.chatStarting))
    }

    func testStoppedChatKeepsTextOnClipboard() {
        XCTAssertEqual(decide(chat(), state: .notRunning), .clipboardOnly(.chatNotRunning))
    }

    func testRouterAsksForTheTargetSession() {
        var askedFor: [UUID] = []
        _ = DictationDeliveryRouter.decide(delivery: chat(), text: "x") { id in
            askedFor.append(id)
            return .ready
        }
        XCTAssertEqual(askedFor, [sessionID])
    }
}
