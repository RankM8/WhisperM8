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
        XCTAssertTrue(KeyboardLegend.ticketItems(for: context(.empty)).isEmpty)
        XCTAssertTrue(KeyboardLegend.ticketItems(for: nil).isEmpty)
    }

    /// WM8-91 Paket 3d per Tastatur: im Kopf Pfeile, Return schaltet, Esc zurück.
    func testHeaderShowsItsKeys() {
        XCTAssertEqual(KeyboardLegend.ticketItems(for: context(.header)).map(\.keys), [["↑", "↓", "←", "→"], ["↩"], ["esc"]])
        XCTAssertEqual(KeyboardLegend.ticketItems(for: context(.headerPicker)).map(\.keys), [["↑", "↓"], ["↩"], ["esc"]])
    }

    /// WM8-91 Paket 3c: auf dem Board die Kürzel aus dem Plan, ⌘J nur mit
    /// sichtbarem Board-Chat.
    func testBoardShowsTheBoardKeys() {
        let keys = KeyboardLegend.ticketItems(for: context(.board)).map(\.keys)
        XCTAssertEqual(keys, [["↑", "↓", "←", "→"], ["↩"], ["⌘", "C"], ["⌘", "⌥", "←", "→"], ["⌘", "O"], ["⌘", "R"], ["⌘", "K"]])
        var place = ControllerTicketsPlace(projectID: UUID(), team: "WM8")
        place.view = .board
        place.boardChatID = UUID()
        place.boardChatName = "Jarvis"
        let withChat = KeyboardLegend.ticketItems(for: .tickets(ControllerTicketState(place: place)))
        XCTAssertTrue(withChat.contains { $0.keys == ["⌘", "J"] && $0.label == "→ Jarvis" })
        XCTAssertEqual(KeyboardLegend.ticketItems(for: context(.chatLine)).first?.keys, ["↩"])
    }
}
