import Foundation
import XCTest
@testable import WhisperM8

/// Workspace-Auswahl des Controllers (L2 halten im Raster, Runde 3): Modell,
/// Einträge aus dem Store und die gemerkte Kachel je Workspace.
@MainActor
final class ControllerWorkspacePickerTests: XCTestCase {
    // MARK: - Modell

    private func choice(_ name: String, current: Bool = false) -> ControllerWorkspaceChoice {
        ControllerWorkspaceChoice(id: UUID(), name: name, colorHex: "#888888", chatCount: 1,
                                  hasWaitingChat: false, isCurrent: current)
    }

    func testModelStartsAtCurrentAndClampsAtEdges() {
        let choices = [choice("A"), choice("B", current: true), choice("C")]
        var model = ControllerWorkspacePickerModel(choices: choices)
        XCTAssertEqual(model.selected?.name, "B")
        model.move(1)
        model.move(1)
        XCTAssertEqual(model.selected?.name, "C", "kein Umlauf")
        model.move(-5)
        XCTAssertEqual(model.selected?.name, "A")
    }

    func testModelWithoutCurrentStartsAtFirst() {
        let model = ControllerWorkspacePickerModel(choices: [choice("A"), choice("B")])
        XCTAssertEqual(model.selected?.name, "A")
        XCTAssertNil(ControllerWorkspacePickerModel(choices: []).selected)
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
