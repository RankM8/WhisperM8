import Foundation
import XCTest
@testable import WhisperM8

/// Zeilen der Liste links für die Navigation ohne Maus: Reihenfolge wie in
/// der Ansicht, eingeklappte Teile ohne Kind-Zeilen.
final class AgentChatsListRowsBuilderTests: XCTestCase {
    private typealias Builder = AgentChatsListRowsBuilder
    private let projectA = UUID()
    private let projectB = UUID()
    private let workspace = UUID()
    private let chat1 = UUID()
    private let chat2 = UUID()
    private let chat3 = UUID()

    private func rows(_ input: Builder.Input) -> [SidebarNavigationRow] {
        Builder.rows(input).map(\.row)
    }

    func testOrderIsPinnedThenWorkspacesThenProjects() {
        let input = Builder.Input(
            pinned: [.init(id: chat1, projectID: projectA)],
            workspaces: [.init(id: workspace, isCollapsed: false, chats: [.init(id: chat2, projectID: projectA)])],
            projects: [.init(id: projectB, isExpanded: true, visibleChats: [chat3], activeSessionIDs: [chat3])]
        )
        XCTAssertEqual(rows(input), [
            .chat(chat1),
            .workspace(workspace), .workspaceChat(session: chat2, workspace: workspace),
            .project(projectB), .chat(chat3),
        ])
    }

    func testCollapsedPartsHaveNoChildren() {
        let input = Builder.Input(
            pinned: [.init(id: chat1, projectID: projectA)],
            isPinnedCollapsed: true,
            workspaces: [.init(id: workspace, isCollapsed: true, chats: [.init(id: chat2, projectID: projectA)])],
            projects: [.init(id: projectB, isExpanded: false, visibleChats: [chat3], activeSessionIDs: [])]
        )
        XCTAssertEqual(rows(input), [.workspace(workspace), .project(projectB)])
    }

    func testCollapsedSectionsDisappearCompletely() {
        let input = Builder.Input(
            workspaces: [.init(id: workspace, isCollapsed: false, chats: [])],
            isWorkspacesCollapsed: true,
            isChatListHidden: true,
            projects: [.init(id: projectA, isExpanded: true, visibleChats: [chat1], activeSessionIDs: [])]
        )
        XCTAssertEqual(rows(input), [])
    }

    func testFlatLayoutListsChatsWithoutProjects() {
        let input = Builder.Input(
            flatChats: [.init(id: chat1, projectID: projectA), .init(id: chat2, projectID: projectB)],
            projects: [.init(id: projectA, isExpanded: true, visibleChats: [chat3], activeSessionIDs: [])]
        )
        XCTAssertEqual(rows(input), [.chat(chat1), .chat(chat2)])
    }

    /// Angeheftet und zugleich in der Liste: nur einmal, an der ersten Stelle.
    func testSameChatAppearsOnce() {
        let input = Builder.Input(
            pinned: [.init(id: chat1, projectID: projectA)],
            projects: [.init(id: projectA, isExpanded: true, visibleChats: [chat1, chat2], activeSessionIDs: [])]
        )
        XCTAssertEqual(rows(input), [.chat(chat1), .project(projectA), .chat(chat2)])
    }

    /// „Neuer Chat“ landet im Projekt der Zeile; Projekt-Zeilen tragen ihre
    /// aktiven Chats für „als Workspace öffnen“.
    func testRowsCarryProjectAndActiveChats() {
        let input = Builder.Input(
            workspaces: [.init(id: workspace, isCollapsed: false, chats: [.init(id: chat2, projectID: projectB)])],
            projects: [.init(id: projectA, isExpanded: true, visibleChats: [chat1], activeSessionIDs: [chat1])]
        )
        let built = Builder.rows(input)
        XCTAssertEqual(built[0].projectID, projectB, "Workspace: Projekt des ersten Chats")
        XCTAssertEqual(built[1].projectID, projectB)
        XCTAssertEqual(built[2], AgentChatsListRow(row: .project(projectA), projectID: projectA, activeSessionIDs: [chat1]))
        XCTAssertEqual(built[3].projectID, projectA)
    }

    func testEmptyWorkspaceStillHasItsHeaderRow() {
        let input = Builder.Input(workspaces: [.init(id: workspace, isCollapsed: false, chats: [])])
        XCTAssertEqual(rows(input), [.workspace(workspace)])
        XCTAssertNil(Builder.rows(input)[0].projectID)
    }
}
