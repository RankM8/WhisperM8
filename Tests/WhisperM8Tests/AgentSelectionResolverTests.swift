import XCTest
@testable import WhisperM8

final class AgentSelectionResolverTests: XCTestCase {
    private func make(_ title: String, status: AgentChatStatus? = nil) -> AgentChatSession {
        var session = AgentChatSession(provider: .claude, projectID: UUID(), title: title, createdManually: true)
        if let status { session.status = status }
        return session
    }

    func testSelectedIDWins() {
        let a = make("A"), b = make("B")
        XCTAssertEqual(AgentSelectionResolver.selected(sessions: [a, b], selectedID: b.id, openTabIDs: [a.id]), b)
    }

    func testArchivedSelectionFallsBackToFirstOpenTabInTabOrder() {
        let a = make("A"), b = make("B"), archived = make("X", status: .archived)
        // Tab-Reihenfolge b vor a, obwohl a in sessions zuerst steht.
        XCTAssertEqual(
            AgentSelectionResolver.selected(sessions: [a, b, archived], selectedID: archived.id,
                                            openTabIDs: [archived.id, b.id, a.id]), b)
    }

    func testNoSelectionUsesFirstOpenTab() {
        let a = make("A"), b = make("B")
        XCTAssertEqual(AgentSelectionResolver.selected(sessions: [a, b], selectedID: nil, openTabIDs: [b.id]), b)
    }

    func testNothingOpenReturnsNil() {
        XCTAssertNil(AgentSelectionResolver.selected(sessions: [make("A")], selectedID: nil, openTabIDs: []))
    }
}
