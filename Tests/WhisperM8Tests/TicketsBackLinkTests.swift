import Foundation
@testable import WhisperM8
import XCTest

/// „← Chats · …“ im Kopf des Boards (WM8-124): Name und Ziel.
final class TicketsBackLinkTests: XCTestCase {
    private let chat = UUID()
    private let otherChat = UUID()
    private let workspace = UUID()

    private func name(_ place: ChatPlace) -> String? {
        switch place {
        case .chat(let id): return id == chat ? "Jarvis: Supervisor WhisperM8" : "Vic · Prüfer"
        case .workspace: return "WM8 Aktiv"
        case .tickets: return "Board"
        }
    }

    func testPreviousWorkspaceIsTheTargetLikeL2() {
        let destination = TicketsBackLink.destination(previous: .workspace(workspace), behind: .chat(chat), name: name)
        XCTAssertEqual(destination, .init(name: "WM8 Aktiv", route: .previousPlace))
        XCTAssertEqual(TicketsBackLink.title(destination), "Chats · WM8 Aktiv")
    }

    func testPlaceBehindTheTicketsOnlyClosesThem() {
        XCTAssertEqual(TicketsBackLink.destination(previous: .workspace(workspace), behind: .workspace(workspace), name: name),
                       .init(name: "WM8 Aktiv", route: .closeTickets))
        XCTAssertEqual(TicketsBackLink.destination(previous: .chat(chat), behind: .chat(chat), name: name),
                       .init(name: "Jarvis: Supervisor WhisperM8", route: .closeTickets))
    }

    func testAnotherChatIsTheTarget() {
        XCTAssertEqual(TicketsBackLink.destination(previous: .chat(otherChat), behind: .chat(chat), name: name),
                       .init(name: "Vic · Prüfer", route: .previousPlace))
    }

    /// Ein anderes Board ist kein Weg zu den Chats: dann was dahinter steht.
    func testAnotherBoardFallsBackToWhatIsBehind() {
        XCTAssertEqual(TicketsBackLink.destination(previous: .tickets(projectID: UUID()), behind: .workspace(workspace), name: name),
                       .init(name: "WM8 Aktiv", route: .closeTickets))
        XCTAssertEqual(TicketsBackLink.destination(previous: nil, behind: .chat(chat), name: name),
                       .init(name: "Jarvis: Supervisor WhisperM8", route: .closeTickets))
    }

    func testWithoutAnyPlaceTheButtonSaysChats() {
        let destination = TicketsBackLink.destination(previous: nil, behind: nil, name: name)
        XCTAssertEqual(destination, .init(name: nil, route: .closeTickets))
        XCTAssertEqual(TicketsBackLink.title(destination), "Chats")
        XCTAssertEqual(TicketsBackLink.title(.init(name: "", route: .closeTickets)), "Chats")
    }

    /// Der Knopf wird nie gekürzt; dafür ist es der Name.
    func testLongNamesAreShortened() {
        let title = TicketsBackLink.title(.init(name: "Jarvis: Supervisor WhisperM8 mit langem Zusatz", route: .previousPlace))
        XCTAssertEqual(title, "Chats · Jarvis: Supervisor Whis…")
        XCTAssertEqual(TicketsBackLink.title(.init(name: "  \u{1B} \n", route: .closeTickets)), "Chats")
    }
}
