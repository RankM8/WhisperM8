import XCTest
@testable import WhisperM8

final class ChatOrderPlannerTests: XCTestCase {
    private let ids = (0..<8).map { _ in UUID() }

    /// Giulianos Fall: Jarvis, Gus, Jon, Vic, Doc, Ole, Dex, Fin → nach Nummer, Jarvis ans Ende.
    func testNamedFirstAndJarvisLast() {
        let (jarvis, gus, jon, vic, doc, ole, dex, fin) = (ids[0], ids[1], ids[2], ids[3], ids[4], ids[5], ids[6], ids[7])
        let current = [jarvis, gus, jon, vic, doc, ole, dex, fin]
        let planned = ChatOrderPlanner.plannedOrder(
            current: current, first: [fin, ole, dex, gus, vic, jon, doc], last: [jarvis])
        XCTAssertEqual(planned, [fin, ole, dex, gus, vic, jon, doc, jarvis])
    }

    func testUnnamedKeepTheirRelativeOrderBehindTheNamed() {
        let current = Array(ids.prefix(5))
        XCTAssertEqual(ChatOrderPlanner.plannedOrder(current: current, first: [ids[3], ids[1]], last: []),
                       [ids[3], ids[1], ids[0], ids[2], ids[4]])
    }

    func testOnlyLastMovesToTheEnd() {
        let current = Array(ids.prefix(4))
        XCTAssertEqual(ChatOrderPlanner.plannedOrder(current: current, first: [], last: [ids[0]]),
                       [ids[1], ids[2], ids[3], ids[0]])
    }

    func testDuplicatesAndUnknownIDsDropOut() {
        let current = Array(ids.prefix(3))
        let stranger = UUID()
        XCTAssertEqual(ChatOrderPlanner.plannedOrder(current: current, first: [ids[2], ids[2], stranger], last: [ids[2]]),
                       [ids[2], ids[0], ids[1]], "einmal genannt zählt die erste Nennung")
    }

    func testSlotsFollowTheOrderAndEmptySlotsStay() {
        let (a, b, c, outsider) = (ids[0], ids[1], ids[2], ids[3])
        let slots: [UUID?] = [c, nil, a, outsider, b]
        XCTAssertEqual(WorkspaceSlotOps.reorderedSlots(slots, order: [a, b, c]), [a, nil, b, c, outsider])
    }

    func testSlotsUnchangedWhenAlreadyInOrder() {
        let slots: [UUID?] = [ids[0], ids[1], nil]
        XCTAssertEqual(WorkspaceSlotOps.reorderedSlots(slots, order: [ids[0], ids[1]]), slots)
    }
}

/// `session.order`: Prüfung und Planung gegen den Workspace (pure, ohne App).
final class SessionOrderPlanTests: XCTestCase {
    private let projectA = AgentProject(name: "whisperm8", path: "/tmp/a")
    private let projectB = AgentProject(name: "listm8", path: "/tmp/b")

    private func session(_ title: String, _ index: Int, project: AgentProject? = nil, archived: Bool = false) -> AgentChatSession {
        AgentChatSession(provider: .claude, projectID: (project ?? projectA).id, title: title,
                         status: archived ? .archived : .running, sortIndex: index)
    }

    func testPlansNumberOrderWithJarvisLast() throws {
        let names = ["Jarvis", "Gus", "Jon", "Vic", "Doc", "Ole", "Dex", "Fin"]
        let sessions = names.enumerated().map { session($0.element, $0.offset) }
        let byName = Dictionary(uniqueKeysWithValues: sessions.map { ($0.title, $0.id) })
        let workspace = AgentWorkspace(projects: [projectA], sessions: sessions)
        let plan = try AgentControlRequestHandler.planSessionOrder(
            workspace: workspace,
            first: ["Fin", "Ole", "Dex", "Gus", "Vic", "Jon", "Doc"].map { byName[$0]! },
            last: [byName["Jarvis"]!]).get()
        XCTAssertEqual(plan.after.map { plan.titles[$0]! }, ["Fin", "Ole", "Dex", "Gus", "Vic", "Jon", "Doc", "Jarvis"])
        XCTAssertEqual(plan.before.map { plan.titles[$0]! }, names)
        XCTAssertEqual(plan.projectName, "whisperm8")
    }

    func testRejectsChatsFromTwoProjects() {
        let a = session("a", 0)
        let b = session("b", 0, project: projectB)
        let workspace = AgentWorkspace(projects: [projectA, projectB], sessions: [a, b])
        guard case .failure(let error) = AgentControlRequestHandler.planSessionOrder(workspace: workspace, first: [a.id, b.id], last: []) else {
            return XCTFail("verschiedene Projekte müssen scheitern")
        }
        XCTAssertEqual(error.code, .invalid)
        XCTAssertTrue(error.message.contains("verschiedenen Projekten"))
    }

    func testRejectsArchivedUnknownAndBothEnds() {
        let a = session("a", 0)
        let old = session("alt", 1, archived: true)
        let workspace = AgentWorkspace(projects: [projectA], sessions: [a, old])
        if case .failure(let error) = AgentControlRequestHandler.planSessionOrder(workspace: workspace, first: [old.id], last: []) {
            XCTAssertEqual(error.code, .notFound)
        } else { XCTFail("archiviert") }
        if case .failure(let error) = AgentControlRequestHandler.planSessionOrder(workspace: workspace, first: [UUID()], last: []) {
            XCTAssertEqual(error.code, .notFound)
        } else { XCTFail("unbekannt") }
        if case .failure(let error) = AgentControlRequestHandler.planSessionOrder(workspace: workspace, first: [a.id], last: [a.id]) {
            XCTAssertEqual(error.code, .invalid)
        } else { XCTFail("vorn und hinten") }
    }

    func testArchivedChatsStayOutOfThePlan() throws {
        let a = session("a", 0)
        let old = session("alt", 1, archived: true)
        let b = session("b", 2)
        let workspace = AgentWorkspace(projects: [projectA], sessions: [a, old, b])
        let plan = try AgentControlRequestHandler.planSessionOrder(workspace: workspace, first: [b.id], last: []).get()
        XCTAssertEqual(plan.after, [b.id, a.id])
    }
}

final class ChatsOrderCommandParseTests: XCTestCase {
    func testParsesRefsLastDryRunAndJson() throws {
        let options = try ChatsOrderCommand.parse(["fin", "ole", "--last", "jarvis", "--dry-run", "--json"])
        XCTAssertEqual(options, .init(first: ["fin", "ole"], last: ["jarvis"], dryRun: true, json: true))
    }

    func testLastAloneIsEnough() throws {
        XCTAssertEqual(try ChatsOrderCommand.parse(["--last", "jarvis"]).last, ["jarvis"])
    }

    func testRejectsEmptyUnknownFlagAndDanglingLast() {
        XCTAssertThrowsError(try ChatsOrderCommand.parse([]))
        XCTAssertThrowsError(try ChatsOrderCommand.parse(["a", "--top"]))
        XCTAssertThrowsError(try ChatsOrderCommand.parse(["a", "--last"]))
        XCTAssertThrowsError(try ChatsOrderCommand.parse(["--last", "--json"]))
    }
}

/// Feld `order` in `chats list/show --json`.
final class ChatsOrderInfoTests: XCTestCase {
    func testSidebarPositionSortIndexAndTabs() {
        let project = AgentProject(name: "whisperm8", path: "/tmp/a")
        let a = AgentChatSession(provider: .claude, projectID: project.id, title: "a", status: .running, sortIndex: 1)
        let b = AgentChatSession(provider: .claude, projectID: project.id, title: "b", status: .running, sortIndex: 0)
        let old = AgentChatSession(provider: .claude, projectID: project.id, title: "alt", status: .archived, sortIndex: 2)
        var ui = AgentUIState()
        let window = AgentChatWindowState(openTabIDs: [a.id, b.id], isPrimary: true)
        ui.windows = [window]
        let info = ChatsOrderInfo.byID(
            workspace: AgentWorkspace(projects: [project], sessions: [a, b, old]), uiState: ui)
        XCTAssertEqual(info[b.id]?["sidebarPosition"] as? Int, 1)
        XCTAssertEqual(info[a.id]?["sidebarPosition"] as? Int, 2)
        XCTAssertTrue(info[old.id]?["sidebarPosition"] is NSNull, "archiviert: keine Position")
        XCTAssertEqual(info[a.id]?["sortIndex"] as? Int, 1)
        let tabs = info[b.id]?["tabs"] as? [[String: Any]]
        XCTAssertEqual(tabs?.first?["position"] as? Int, 2)
        XCTAssertEqual(tabs?.first?["windowID"] as? String, window.id.uuidString)
        XCTAssertEqual((info[old.id]?["tabs"] as? [[String: Any]])?.count, 0)
    }
}
