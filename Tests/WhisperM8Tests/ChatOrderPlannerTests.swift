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

    /// Tabs: Projekt-Tabs als Block an die Stelle des ersten, andere bleiben.
    func testTabBlockReplacesTheFirstProjectTab() {
        let (x, a, y, b, c, z) = (ids[0], ids[1], ids[2], ids[3], ids[4], ids[5])
        let window = [x, a, y, b, z, c]
        XCTAssertEqual(ChatOrderPlanner.tabBlockOrder(window: window, block: [c, a, b]), [x, c, a, b, y, z])
        XCTAssertEqual(ChatOrderPlanner.tabBlockOrder(window: [x, y], block: [a]), [x, y], "Block nicht im Fenster: unverändert")
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
                         status: archived ? .archived : .running, sortIndex: index, createdManually: true)
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

    func testRejectsPinnedAndHiddenChatsButIgnoresThemInThePlan() throws {
        let a = session("a", 0)
        let pinned = session("gepinnt", 1)
        var job = session("job", 2)
        job.createdManually = false
        let b = session("b", 3)
        let workspace = AgentWorkspace(projects: [projectA], sessions: [a, pinned, job, b])
        if case .failure(let error) = AgentControlRequestHandler.planSessionOrder(
            workspace: workspace, pinnedIDs: [pinned.id], first: [pinned.id], last: []) {
            XCTAssertEqual(error.code, .invalid)
            XCTAssertTrue(error.message.contains("gepinnt"))
        } else { XCTFail("gepinnt") }
        if case .failure(let error) = AgentControlRequestHandler.planSessionOrder(
            workspace: workspace, pinnedIDs: [pinned.id], first: [job.id], last: []) {
            XCTAssertEqual(error.code, .invalid)
        } else { XCTFail("nicht von Hand angelegt") }
        let plan = try AgentControlRequestHandler.planSessionOrder(
            workspace: workspace, pinnedIDs: [pinned.id], first: [b.id], last: []).get()
        XCTAssertEqual(plan.after, [b.id, a.id], "nur die sichtbare Projektgruppe")
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
        let a = AgentChatSession(provider: .claude, projectID: project.id, title: "a", status: .running, sortIndex: 1, createdManually: true)
        let b = AgentChatSession(provider: .claude, projectID: project.id, title: "b", status: .running, sortIndex: 0, createdManually: true)
        let old = AgentChatSession(provider: .claude, projectID: project.id, title: "alt", status: .archived, sortIndex: 2, createdManually: true)
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

final class TabOrderPlanTests: XCTestCase {
    private let projectA = AgentProject(name: "whisperm8", path: "/tmp/a")
    private let projectB = AgentProject(name: "listm8", path: "/tmp/b")

    private func chat(_ title: String, _ project: AgentProject) -> AgentChatSession {
        AgentChatSession(provider: .claude, projectID: project.id, title: title, status: .running, createdManually: true)
    }

    func testOrdersTheProjectTabsOfOneWindow() throws {
        let (jarvis, dex, ole, other) = (chat("Jarvis", projectA), chat("Dex", projectA), chat("Ole", projectA), chat("ListM8", projectB))
        let window = UUID()
        let workspace = AgentWorkspace(projects: [projectA, projectB], sessions: [jarvis, dex, ole, other])
        let plan = try AgentControlRequestHandler.planTabOrder(
            windows: [(id: window, tabs: [other.id, jarvis.id, dex.id, ole.id])], workspace: workspace,
            first: [ole.id, dex.id], last: [jarvis.id]).get()
        XCTAssertEqual(plan.windowID, window)
        XCTAssertEqual(plan.after, [other.id, ole.id, dex.id, jarvis.id])
    }

    func testRejectsClosedTabsTwoWindowsAndTwoProjects() {
        let (a, b, c) = (chat("a", projectA), chat("b", projectA), chat("c", projectB))
        let workspace = AgentWorkspace(projects: [projectA, projectB], sessions: [a, b, c])
        let w1 = (id: UUID(), tabs: [a.id, c.id])
        let w2 = (id: UUID(), tabs: [b.id])
        if case .failure(let error) = AgentControlRequestHandler.planTabOrder(windows: [w1], workspace: workspace, first: [b.id], last: []) {
            XCTAssertEqual(error.code, .notFound)
        } else { XCTFail("nicht offen") }
        if case .failure(let error) = AgentControlRequestHandler.planTabOrder(windows: [w1, w2], workspace: workspace, first: [a.id, b.id], last: []) {
            XCTAssertEqual(error.code, .invalid)
            XCTAssertTrue(error.message.contains("Fenstern"))
        } else { XCTFail("zwei Fenster") }
        if case .failure(let error) = AgentControlRequestHandler.planTabOrder(windows: [w1], workspace: workspace, first: [a.id, c.id], last: []) {
            XCTAssertEqual(error.code, .invalid)
            XCTAssertTrue(error.message.contains("Tab-Gruppen"))
        } else { XCTFail("zwei Projekte") }
    }

    /// Tab-Leiste gruppiert Raster-Workspace vor Projekt: Ein Tab im Workspace
    /// gehört nicht zur Projektgruppe.
    func testTabGroupFollowsTheTabStripGrouping() throws {
        let (a1, a2, a3) = (chat("a1", projectA), chat("a2", projectA), chat("a3", projectA))
        let gridID = UUID()
        let window = (id: UUID(), tabs: [a1.id, a2.id, a3.id])
        let workspace = AgentWorkspace(projects: [projectA], sessions: [a1, a2, a3])
        if case .failure(let error) = AgentControlRequestHandler.planTabOrder(
            windows: [window], workspace: workspace, workspaceBySession: [a1.id: gridID],
            first: [a3.id, a1.id], last: []) {
            XCTAssertTrue(error.message.contains("Tab-Gruppen"))
        } else { XCTFail("Workspace-Tab und Projekt-Tab sind verschiedene Gruppen") }
        let plan = try AgentControlRequestHandler.planTabOrder(
            windows: [window], workspace: workspace, workspaceBySession: [a1.id: gridID],
            first: [a3.id], last: []).get()
        XCTAssertEqual(plan.after, [a1.id, a3.id, a2.id], "nur a2 und a3 bilden die Projektgruppe")
    }

    func testParsesTabsFlag() throws {
        XCTAssertTrue(try ChatsOrderCommand.parse(["--tabs", "dex", "--last", "jarvis"]).tabs)
    }
}
