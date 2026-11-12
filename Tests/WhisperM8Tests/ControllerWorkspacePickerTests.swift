import Foundation
import XCTest
@testable import WhisperM8

/// Workspaces am Controller (seit Runde 4 der Reiter „Workspaces“ der Insel):
/// Liste, Einträge aus dem Store und die gemerkte Kachel je Workspace.
@MainActor
final class ControllerWorkspacePickerTests: XCTestCase {
    // MARK: - Reiter Workspaces der Insel

    private func choice(_ name: String, current: Bool = false) -> ControllerWorkspaceChoice {
        ControllerWorkspaceChoice(id: UUID(), name: name, colorHex: "#888888", chatCount: 1,
                                  hasWaitingChat: false, isCurrent: current)
    }

    func testListStartsAtCurrentAndClampsAtEdges() {
        let choices = [choice("A"), choice("B", current: true), choice("C")]
        var list = ControllerIslandList(rows: choices, currentID: choices[1].id)
        XCTAssertEqual(list.selected?.name, "B")
        list.move(1)
        list.move(1)
        XCTAssertEqual(list.selected?.name, "C", "kein Umlauf")
        list.move(-5)
        XCTAssertEqual(list.selected?.name, "A")
    }

    func testListWithoutCurrentStartsAtFirst() {
        let list = ControllerIslandList(rows: [choice("A"), choice("B")], currentID: nil)
        XCTAssertEqual(list.selected?.name, "A")
        XCTAssertFalse(list.startsAtCurrent)
        XCTAssertNil(ControllerIslandList<ControllerWorkspaceChoice>(rows: [], currentID: nil).selected)
    }

    /// Review nach Runde 4, Punkt 3: Loslassen wechselt nur nach einer
    /// Bewegung im sichtbaren Reiter.
    func testDestinationNeedsAMoveInTheVisibleTab() {
        let chatRows = [UUID(), UUID()].map {
            ControllerIslandChatRow(id: $0, title: "C", project: nil, status: .idle, detail: "", isCurrent: false)
        }
        let choices = [choice("A"), choice("B")]
        var state = ControllerWhereToState(chats: chatRows, currentChatID: nil, workspaces: choices, gridActive: false)
        XCTAssertEqual(state.destination, .stay, "Liste zu")
        state.switchTab(1)
        XCTAssertTrue(state.isListOpen)
        XCTAssertEqual(state.destination, .stay, "nur Reiter gewechselt")
        state.move(1)
        XCTAssertEqual(state.destination, .workspace(choices[1].id))
        state.switchTab(-1)
        XCTAssertEqual(state.destination, .stay, "neuer Reiter, noch nicht bewegt")
        state.move(1)
        XCTAssertEqual(state.destination, .chat(chatRows[1].id))
    }

    /// Review nach Runde 4, Punkt 2: Ohne sichtbare Menüleiste (Vollbild)
    /// hängt die Pille oben am Rand; an der Notch liegt das Band in der Aussparung.
    func testIslandGeometryWithAndWithoutMenuBar() {
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let fullscreen = NotchScreenInfo(displayID: 1, frame: frame, visibleFrame: frame, safeAreaTop: 0,
                                         auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, isBuiltIn: false)
        XCTAssertEqual(ControllerIslandGeometry.frame(screen: fullscreen, bodySize: CGSize(width: 400, height: 100)),
                       CGRect(x: 600, y: 1000 - 6 - 100, width: 400, height: 100))
        var withMenuBar = fullscreen
        withMenuBar.visibleFrame = CGRect(x: 0, y: 0, width: 1600, height: 975)
        XCTAssertEqual(ControllerIslandGeometry.frame(screen: withMenuBar, bodySize: CGSize(width: 400, height: 100)).maxY,
                       1000 - 25 - 6)
        let notch = NotchScreenInfo(displayID: 2, frame: frame, visibleFrame: frame, safeAreaTop: 32,
                                    auxiliaryLeftWidth: 700, auxiliaryRightWidth: 700, isBuiltIn: true)
        let island = ControllerIslandGeometry.frame(screen: notch, bodySize: CGSize(width: 440, height: 200))
        XCTAssertEqual(island.maxY, 1000, "bündig an der Oberkante, auch im Vollbild")
        XCTAssertEqual(island.midX, 800)
    }

    // MARK: - Einträge

    /// Nur angelegte Workspaces in der Reihenfolge der Seitenleiste; Zahl der
    /// belegten Slots; „wartet“ nur bei `awaitingInput`.
    func testChoicesSkipProjectViewsAndUseAwaitingStatus() {
        let a = UUID(), b = UUID(), c = UUID()
        let curated1 = AgentGridWorkspace(name: "Eins", slots: [a, nil, b], capacity: 3)
        let projectView = AgentGridWorkspace(name: "Projekt", slots: [c], sourceProjectID: UUID())
        let curated2 = AgentGridWorkspace(name: "Zwei", slots: [c], capacity: 2)
        let statuses: [UUID: AgentSessionRuntimeStatus] = [a: .working, b: .idle, c: .awaitingInput]

        let choices = ControllerWorkspaceChoice.choices(
            from: [curated1, projectView, curated2], currentID: curated2.id, status: { statuses[$0] })
        XCTAssertEqual(choices.map(\.name), ["Eins", "Zwei"])
        XCTAssertEqual(choices.map(\.chatCount), [2, 1])
        XCTAssertEqual(choices.map(\.hasWaitingChat), [false, true])
        XCTAssertEqual(choices.map(\.isCurrent), [false, true])
    }

    // MARK: - Gemerkte Kachel je Workspace

    private func makeStore() -> (store: AgentWindowStore, persistence: AgentSessionStore) {
        let dir = FileManager.default.temporaryDirectory
        let persistence = AgentSessionStore(
            fileURL: dir.appendingPathComponent("wm8-wspicker-ws-\(UUID().uuidString).json"),
            uiStateFileURL: dir.appendingPathComponent("wm8-wspicker-ui-\(UUID().uuidString).json"))
        return (AgentWindowStore(persistence: persistence), persistence)
    }

    private func seed(_ persistence: AgentSessionStore, count: Int) throws -> [UUID] {
        try (0 ..< count).map { _ in
            let session = AgentChatSession(
                id: UUID(), provider: .claude, projectID: UUID(), title: "Chat",
                lastActivityAt: Date(timeIntervalSince1970: 1_000), createdManually: true)
            _ = try persistence.upsertSession(session)
            return session.id
        }
    }

    /// Nach dem Wechsel ist die Kachel fokussiert, auf der man in diesem
    /// Workspace zuletzt war — beim ersten Besuch die erste.
    func testSwitchingBackRestoresLastTileOfThatWorkspace() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 4)
        let wsA = store.createGridWorkspace(name: "A", slots: [s[0], s[1]], activateIn: w)
        let wsB = store.createGridWorkspace(name: "B", slots: [s[2], s[3]])
        store.setGridFocusedSession(s[1], in: w)

        XCTAssertEqual(store.activateGridWorkspace(wsB, in: w), .activated)
        XCTAssertEqual(store.selectedSession(in: w), s[2], "erster Besuch: erste Kachel")
        store.setGridFocusedSession(s[3], in: w)

        XCTAssertEqual(store.activateGridWorkspace(wsA, in: w), .activated)
        XCTAssertEqual(store.selectedSession(in: w), s[1], "zurück in A: zuletzt benutzte Kachel")
        XCTAssertEqual(store.activateGridWorkspace(wsB, in: w), .activated)
        XCTAssertEqual(store.selectedSession(in: w), s[3], "zurück in B: zuletzt benutzte Kachel")
    }

    /// Auch aus der Einzelansicht heraus gilt die Kachel, die das Raster
    /// zuletzt hatte; ein inzwischen entfernter Chat fällt auf die erste zurück.
    func testRememberedTileSurvivesSingleViewAndFallsBackWhenRemoved() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 5)
        let wsA = store.createGridWorkspace(name: "A", slots: [s[0], s[1]], activateIn: w)
        let wsB = store.createGridWorkspace(name: "B", slots: [s[2], s[3]])
        store.setGridFocusedSession(s[1], in: w)
        store.showSingleSession(s[4], in: w)

        XCTAssertEqual(store.activateGridWorkspace(wsB, in: w), .activated)
        XCTAssertEqual(store.activateGridWorkspace(wsA, in: w), .activated)
        XCTAssertEqual(store.selectedSession(in: w), s[1], "Kachel vor der Einzelansicht")

        XCTAssertEqual(store.activateGridWorkspace(wsB, in: w), .activated)
        store.removeSession(s[1], fromGridWorkspace: wsA)
        XCTAssertEqual(store.activateGridWorkspace(wsA, in: w), .activated)
        XCTAssertEqual(store.selectedSession(in: w), s[0])
    }
}
