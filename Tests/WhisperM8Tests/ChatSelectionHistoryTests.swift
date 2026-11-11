import Foundation
import XCTest
@testable import WhisperM8

/// „Zurück zum letzten Chat“: Gedächtnis der letzten beiden Auswahlen.
final class ChatSelectionHistoryTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    private let always: (UUID) -> Bool = { _ in true }

    func testEmptyHistoryHasNoTarget() {
        XCTAssertNil(ChatSelectionHistory().lastChat(isAvailable: always))
    }

    func testFirstSelectionAloneHasNoTarget() {
        var history = ChatSelectionHistory()
        history.record(a)
        XCTAssertNil(history.lastChat(isAvailable: always))
    }

    func testSecondSelectionPointsBackToFirst() {
        var history = ChatSelectionHistory()
        history.record(a)
        history.record(b)
        XCTAssertEqual(history.lastChat(isAvailable: always), a)
    }

    /// Hin und her: Nach dem Rücksprung ist der andere Chat das Ziel.
    func testJumpingBackAndForthAlternates() {
        var history = ChatSelectionHistory()
        history.record(a)
        history.record(b)
        history.record(a)
        XCTAssertEqual(history.lastChat(isAvailable: always), b)
        history.record(b)
        XCTAssertEqual(history.lastChat(isAvailable: always), a)
    }

    func testOnlyTheLastTwoCount() {
        var history = ChatSelectionHistory()
        history.record(a)
        history.record(b)
        history.record(c)
        XCTAssertEqual(history.lastChat(isAvailable: always), b)
    }

    func testRecordingSameSelectionAgainChangesNothing() {
        var history = ChatSelectionHistory()
        history.record(a)
        history.record(b)
        history.record(b)
        XCTAssertEqual(history.lastChat(isAvailable: always), a)
    }

    /// Ein geschlossener oder archivierter Chat darf nicht wieder aufgehen.
    func testUnavailableTargetIsNotOffered() {
        var history = ChatSelectionHistory()
        history.record(a)
        history.record(b)
        XCTAssertNil(history.lastChat(isAvailable: { $0 != self.a }))
    }

    /// Kurz keine Auswahl (letzter Tab zu, dann neuer Chat): Der vorige Chat
    /// bleibt das Rücksprungziel.
    func testEmptySelectionKeepsPreviousAsTarget() {
        var history = ChatSelectionHistory()
        history.record(a)
        history.record(nil)
        XCTAssertEqual(history.lastChat(isAvailable: always), a)
        history.record(b)
        XCTAssertEqual(history.lastChat(isAvailable: always), a)
    }
}
