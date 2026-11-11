import Foundation
import XCTest
@testable import WhisperM8

/// Ausgabemodus-Wechsel während der Aufnahme.
final class ControllerOutputModeCyclerTests: XCTestCase {
    private let modes = ["clean", "email", "slack"]

    func testStepsWithWrapAround() {
        XCTAssertEqual(OutputModeCycler.next(current: "clean", in: modes, step: 1), "email")
        XCTAssertEqual(OutputModeCycler.next(current: "slack", in: modes, step: 1), "clean")
        XCTAssertEqual(OutputModeCycler.next(current: "clean", in: modes, step: -1), "slack")
        XCTAssertEqual(OutputModeCycler.next(current: "email", in: modes, step: -4), "clean")
        XCTAssertEqual(OutputModeCycler.next(current: "email", in: modes, step: 0), "email")
    }

    func testEmptyAndUnknown() {
        XCTAssertNil(OutputModeCycler.next(current: "clean", in: [String](), step: 1))
        XCTAssertEqual(OutputModeCycler.next(current: "gone", in: modes, step: 1), "clean")
        XCTAssertEqual(OutputModeCycler.next(current: nil, in: modes, step: -1), "clean")
    }
}

/// Markierung in der Liste links (Plan 3.5).
final class ControllerSidebarNavigationModelTests: XCTestCase {
    private let workspace = UUID()
    private let project = UUID()
    private let chatA = UUID()
    private let chatB = UUID()
    private let chatC = UUID()

    /// Workspaces mit ihren Chats, dann Projekte mit ihren Chats.
    private var rows: [SidebarNavigationRow] {
        [
            .workspace(workspace),
            .workspaceChat(session: chatA, workspace: workspace),
            .project(project),
            .chat(chatA),
            .chat(chatB),
            .chat(chatC),
        ]
    }

    func testMoveWithoutWrapAround() {
        var model = SidebarNavigationModel(rows: rows)
        XCTAssertNil(model.marked)
        model.move(1)
        XCTAssertEqual(model.marked, .workspace(workspace), "ohne Markierung beginnt sie oben")
        model.move(-1)
        XCTAssertEqual(model.marked, .workspace(workspace), "bleibt am oberen Rand stehen")
        model.move(3)
        XCTAssertEqual(model.marked, .chat(chatA))
        model.move(10)
        XCTAssertEqual(model.marked, .chat(chatC), "bleibt am unteren Rand stehen")
    }

    func testStartPrefersChatRowOfSession() {
        var model = SidebarNavigationModel(rows: rows)
        model.start(at: chatA)
        XCTAssertEqual(model.marked, .chat(chatA))
    }

    func testStartFallsBackToWorkspaceChatThenFirstRow() {
        let other = UUID()
        var model = SidebarNavigationModel(rows: [
            .workspace(workspace), .workspaceChat(session: other, workspace: workspace), .project(project),
        ])
        model.start(at: other)
        XCTAssertEqual(model.marked, .workspaceChat(session: other, workspace: workspace))
        model.start(at: UUID())
        XCTAssertEqual(model.marked, .workspace(workspace))
        model.start(at: nil)
        XCTAssertEqual(model.marked, .workspace(workspace))
        var empty = SidebarNavigationModel()
        empty.start(at: chatA)
        XCTAssertNil(empty.marked)
    }

    func testSetRowsKeepsMarkedRow() {
        var model = SidebarNavigationModel(rows: rows, marked: .chat(chatB))
        model.setRows(rows.reversed())
        XCTAssertEqual(model.marked, .chat(chatB))
    }

    func testVanishedRowTakesNeighbourAtSamePosition() {
        var model = SidebarNavigationModel(rows: rows, marked: .chat(chatB))
        model.setRows(rows.filter { $0 != .chat(chatB) })
        XCTAssertEqual(model.marked, .chat(chatC), "die Zeile, die an die Stelle rückt")

        model.setRows([.workspace(workspace), .project(project)])
        XCTAssertEqual(model.marked, .project(project), "am Ende die letzte Zeile")
    }

    /// Eingeklappte Gruppe: ihre Chat-Zeilen verschwinden, die Markierung bleibt in der Nähe.
    func testCollapsedGroup() {
        var model = SidebarNavigationModel(rows: rows, marked: .workspaceChat(session: chatA, workspace: workspace))
        model.setRows(rows.filter {
            if case .workspaceChat = $0 { return false }
            return true
        })
        XCTAssertEqual(model.marked, .project(project))
    }

    func testEmptyRowsClearMarking() {
        var model = SidebarNavigationModel(rows: rows, marked: .chat(chatA))
        model.setRows([])
        XCTAssertNil(model.marked)
        model.move(1)
        XCTAssertNil(model.marked)
    }

    func testInitDropsUnknownMarking() {
        XCTAssertNil(SidebarNavigationModel(rows: rows, marked: .chat(UUID())).marked)
    }
}

/// Menü hinter Options.
final class ControllerMenuModelTests: XCTestCase {
    func testItemsAreFixedAndGreyedDuringQuestion() {
        let model = ControllerMenuModel()
        XCTAssertEqual(model.items(dialogOpen: false).map(\.item), ControllerMenuItem.allCases)
        XCTAssertTrue(model.items(dialogOpen: false).allSatisfy(\.enabled))
        let disabled = model.items(dialogOpen: true).filter { !$0.enabled }.map(\.item)
        XCTAssertEqual(disabled, [.continueWork, .slashCommands, .compact])
    }

    func testMoveWrapsAround() {
        var model = ControllerMenuModel(selected: .pause)
        model.move(1, dialogOpen: false)
        XCTAssertEqual(model.selected, .continueWork)
        model.move(-1, dialogOpen: false)
        XCTAssertEqual(model.selected, .pause)
        model.move(2, dialogOpen: false)
        XCTAssertEqual(model.selected, .slashCommands)
    }

    func testMoveSkipsDisabledItems() {
        var model = ControllerMenuModel(selected: .cycleMode)
        model.move(1, dialogOpen: true)
        XCTAssertEqual(model.selected, .closeTab, "überspringt /compact")
        model.move(-1, dialogOpen: true)
        XCTAssertEqual(model.selected, .cycleMode)
        model.move(-1, dialogOpen: true)
        XCTAssertEqual(model.selected, .pause, "überspringt Weiter und Befehlsliste, mit Umlauf")
    }

    func testNormalizeLeavesDisabledSelection() {
        var model = ControllerMenuModel()
        model.normalize(dialogOpen: true)
        XCTAssertEqual(model.selected, .cycleMode)
        model.normalize(dialogOpen: true)
        XCTAssertEqual(model.selected, .cycleMode)
    }
}
