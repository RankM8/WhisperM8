import Foundation
import XCTest
@testable import WhisperM8

/// Auswahl für den Controller (WM8-91): „N weitere“ als eigene Stelle, der
/// Rand als Rückgabe, Bewegen in der Liste und der Fokus auf den Chat-Zeilen
/// der Triage. Pur, wie die Tab-Logik.
final class TicketBoardSelectionControllerTests: XCTestCase {
    /// Drei Spalten: A mit zwei Karten und „3 weitere“, B eingeklappt, C mit
    /// einer Karte.
    private let columns = [
        TicketBoardColumnKeys(id: "a", keys: ["WM8-1", "WM8-2"], hidden: 3, isFolded: false, firstHiddenKey: "WM8-3"),
        TicketBoardColumnKeys(id: "b", keys: [], hidden: 0, isFolded: true),
        TicketBoardColumnKeys(id: "c", keys: ["WM8-9"], hidden: 0, isFolded: false),
    ]

    private func step(_ spot: TicketBoardSpot?, _ direction: TicketBoardMove) -> TicketBoardStep {
        TicketBoardSelection.step(spot, direction, in: columns)
    }

    func testWithoutSpotTheFirstStepLandsOnTheStart() {
        XCTAssertEqual(step(nil, .down), TicketBoardStep(spot: .card("WM8-1")))
    }

    func testMoreIsItsOwnSpotBelowTheCards() {
        XCTAssertEqual(step(.card("WM8-2"), .down), TicketBoardStep(spot: .more(column: "a")))
        XCTAssertEqual(step(.more(column: "a"), .up), TicketBoardStep(spot: .card("WM8-2")))
        XCTAssertEqual(step(.more(column: "a"), .down), TicketBoardStep(spot: .more(column: "a"), edge: .bottom))
    }

    func testEdgesComeBackAsValues() {
        XCTAssertEqual(step(.card("WM8-1"), .up), TicketBoardStep(spot: .card("WM8-1"), edge: .top))
        XCTAssertEqual(step(.card("WM8-1"), .left), TicketBoardStep(spot: .card("WM8-1"), edge: .left),
                       "links aus der ersten Spalte: der Controller geht in die Seitenleiste")
        XCTAssertEqual(step(.card("WM8-9"), .right), TicketBoardStep(spot: .card("WM8-9"), edge: .right))
        XCTAssertEqual(step(.card("WM8-9"), .down), TicketBoardStep(spot: .card("WM8-9"), edge: .bottom))
    }

    /// Sprung über die eingeklappte Spalte; die Höhe bleibt so nah wie möglich.
    func testSidewaysSkipsFoldedColumnsAndKeepsTheHeight() {
        XCTAssertEqual(step(.card("WM8-2"), .right), TicketBoardStep(spot: .card("WM8-9")))
        XCTAssertEqual(step(.more(column: "a"), .right), TicketBoardStep(spot: .card("WM8-9")))
        XCTAssertEqual(step(.card("WM8-9"), .left), TicketBoardStep(spot: .card("WM8-1")))
    }

    func testSidewaysIntoMore() {
        let wide = [
            TicketBoardColumnKeys(id: "x", keys: ["A-1", "A-2", "A-3"], hidden: 0, isFolded: false),
            TicketBoardColumnKeys(id: "y", keys: ["B-1"], hidden: 4, isFolded: false, firstHiddenKey: "B-2"),
        ]
        XCTAssertEqual(TicketBoardSelection.step(.card("A-3"), .right, in: wide), TicketBoardStep(spot: .more(column: "y")))
    }

    /// Kreuz auf „N weitere“ öffnet beim ersten verborgenen Ticket, wie der
    /// Knopf in der Ansicht.
    func testOpenKey() {
        XCTAssertEqual(TicketBoardSelection.openKey(.more(column: "a"), in: columns), "WM8-3")
        XCTAssertEqual(TicketBoardSelection.openKey(.card("WM8-9"), in: columns), "WM8-9")
        XCTAssertNil(TicketBoardSelection.openKey(.card("WM8-77"), in: columns))
        XCTAssertNil(TicketBoardSelection.openKey(nil, in: columns))
    }

    /// L1/R1: die Spalte hinunter, dann oben in der nächsten; am Ende Rand.
    func testReadingOrder() {
        XCTAssertEqual(TicketBoardSelection.readingOrder(columns), ["WM8-1", "WM8-2", "WM8-9"])
        XCTAssertEqual(TicketBoardSelection.adjacent(.card("WM8-2"), 1, in: columns), TicketBoardStep(spot: .card("WM8-9")))
        XCTAssertEqual(TicketBoardSelection.adjacent(.card("WM8-9"), 1, in: columns),
                       TicketBoardStep(spot: .card("WM8-9"), edge: .bottom))
        XCTAssertEqual(TicketBoardSelection.adjacent(.card("WM8-1"), -1, in: columns),
                       TicketBoardStep(spot: .card("WM8-1"), edge: .top))
        XCTAssertEqual(TicketBoardSelection.adjacent(.more(column: "a"), 1, in: columns), TicketBoardStep(spot: .card("WM8-9")))
        XCTAssertEqual(TicketBoardSelection.adjacent(.more(column: "a"), -1, in: columns), TicketBoardStep(spot: .card("WM8-2")))
        XCTAssertEqual(TicketBoardSelection.adjacent(nil, 1, in: columns), TicketBoardStep(spot: .card("WM8-1")))
    }

    func testAMoreSpotThatVanishedStartsOver() {
        let shrunk = [TicketBoardColumnKeys(id: "a", keys: ["WM8-1"], hidden: 0, isFolded: false)]
        XCTAssertNil(TicketBoardSelection.place(of: .more(column: "a"), in: shrunk))
        XCTAssertEqual(TicketBoardSelection.step(.more(column: "a"), .down, in: shrunk), TicketBoardStep(spot: .card("WM8-1")))
    }

    func testListMode() {
        let keys = ["WM8-1", "WM8-2", "WM8-3"]
        XCTAssertEqual(TicketBoardSelection.stepInList(nil, .down, keys: keys).key, "WM8-1")
        XCTAssertEqual(TicketBoardSelection.stepInList("WM8-1", .down, keys: keys).key, "WM8-2")
        XCTAssertEqual(TicketBoardSelection.stepInList("WM8-1", .up, keys: keys).edge, .top)
        XCTAssertEqual(TicketBoardSelection.stepInList("WM8-3", .down, keys: keys).edge, .bottom)
        XCTAssertEqual(TicketBoardSelection.stepInList("WM8-2", .left, keys: keys).edge, .left)
        XCTAssertEqual(TicketBoardSelection.stepInList("WM8-2", .right, keys: keys).key, "WM8-2")
        XCTAssertNil(TicketBoardSelection.stepInList(nil, .down, keys: []).key)
    }

    func testTriageFocus() {
        XCTAssertEqual(TicketBoardSelection.triageStep(.list, .down, chatCount: 2), .ticket(1))
        XCTAssertEqual(TicketBoardSelection.triageStep(.list, .up, chatCount: 2), .ticket(-1))
        XCTAssertEqual(TicketBoardSelection.triageStep(.list, .right, chatCount: 2), .focus(.chat(0)))
        XCTAssertEqual(TicketBoardSelection.triageStep(.list, .right, chatCount: 0), .edge(.right),
                       "ohne Chats am Ticket keine Chat-Zeile")
        XCTAssertEqual(TicketBoardSelection.triageStep(.list, .left, chatCount: 2), .edge(.left))
        XCTAssertEqual(TicketBoardSelection.triageStep(.chat(0), .down, chatCount: 2), .focus(.chat(1)))
        XCTAssertEqual(TicketBoardSelection.triageStep(.chat(1), .down, chatCount: 2), .edge(.bottom))
        XCTAssertEqual(TicketBoardSelection.triageStep(.chat(0), .up, chatCount: 2), .edge(.top))
        XCTAssertEqual(TicketBoardSelection.triageStep(.chat(1), .left, chatCount: 2), .focus(.list))
        XCTAssertEqual(TicketBoardSelection.triageStep(.chat(1), .right, chatCount: 2), .edge(.right),
                       "rechts kommt mit WM8-113 der Board-Chat")
        XCTAssertEqual(TicketBoardSelection.reconcile(.chat(3), chatCount: 2), .chat(1))
        XCTAssertEqual(TicketBoardSelection.reconcile(.chat(0), chatCount: 0), .list)
        XCTAssertEqual(TicketBoardSelection.reconcile(.list, chatCount: 0), .list)
    }

    func testControllerStart() {
        XCTAssertEqual(TicketBoardSelection.controllerStart(preferred: "WM8-9", waiting: "WM8-2", in: columns), "WM8-9",
                       "das Ticket des Chats, aus dem man kommt")
        XCTAssertEqual(TicketBoardSelection.controllerStart(preferred: "WM8-3", waiting: "WM8-9", in: columns), "WM8-9",
                       "verborgen zählt nicht; dann die erste wartende Spalte")
        XCTAssertEqual(TicketBoardSelection.controllerStart(preferred: nil, waiting: nil, in: columns), "WM8-1")
    }
}
