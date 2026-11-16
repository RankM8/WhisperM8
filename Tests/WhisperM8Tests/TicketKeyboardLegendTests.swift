import Foundation
@testable import WhisperM8
import XCTest

/// Tasten der Triage in der Leiste unten statt abgeschnitten im Ticket-Kopf (WM8-124).
final class TicketKeyboardLegendTests: XCTestCase {
    private func context(_ view: ControllerTicketView) -> ControllerContext {
        var place = ControllerTicketsPlace(projectID: UUID(), team: "WM8")
        place.view = view
        return .tickets(ControllerTicketState(place: place))
    }

    func testTriageShowsTheTicketKeys() {
        let keys = KeyboardLegend.ticketItems(for: context(.triage)).map(\.keys)
        XCTAssertEqual(keys, [["J", "K"], ["⌘", "C"], ["esc"]])
        XCTAssertEqual(KeyboardLegend.ticketItems(for: context(.chatLine)).count, 3)
    }

    func testOtherPlacesShowNoTicketKeys() {
        XCTAssertTrue(KeyboardLegend.ticketItems(for: context(.board)).isEmpty)
        XCTAssertTrue(KeyboardLegend.ticketItems(for: context(.empty)).isEmpty)
        XCTAssertTrue(KeyboardLegend.ticketItems(for: nil).isEmpty)
    }
}
