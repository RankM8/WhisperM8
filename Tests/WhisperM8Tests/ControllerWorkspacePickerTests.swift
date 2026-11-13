import Foundation
import XCTest
@testable import WhisperM8

/// Workspaces und Projekte am Controller (Reiter „Workspaces & Projekte“ der Insel):
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
        var list = ControllerIslandList(rows: choices, startID: choices[1].id)
        XCTAssertEqual(list.selected?.name, "B")
        list.move(1)
        list.move(1)
        XCTAssertEqual(list.selected?.name, "C", "kein Umlauf")
        list.move(-5)
        XCTAssertEqual(list.selected?.name, "A")
    }

    /// Ohne Startpunkt keine Markierung: Loslassen darf dann nicht aus
    /// Versehen zur ersten Zeile wechseln. Der erste Stoß markiert sie.
    func testListWithoutStartHasNoMarkerUntilTheFirstMove() {
        var list = ControllerIslandList(rows: [choice("A"), choice("B")], startID: nil)
        XCTAssertNil(list.selected)
        list.move(1)
        XCTAssertEqual(list.selected?.name, "A")
        XCTAssertNil(ControllerIslandList<ControllerWorkspaceChoice>(rows: [], startID: nil).selected)
    }

    private func chatRows(_ count: Int, current: Int? = nil) -> [ControllerIslandChatRow] {
        (0..<count).map {
            ControllerIslandChatRow(id: UUID(), title: "C\($0)", project: nil, status: .idle, detail: "",
                                    isCurrent: $0 == current)
        }
    }

    /// Insel-Paket: Die Markierung beginnt auf dem aktuellen Chat, nicht auf
    /// dem vorigen. Loslassen ohne Bewegung tut nichts; der vorige Chat trägt
    /// „vorher“ und ist einen Schritt entfernt.
    func testMarkerStartsOnTheCurrentChatAndPreviousIsOneStepAway() {
        let chats = chatRows(3, current: 1)
        var state = ControllerWhereToState(
            chats: chats, currentChatID: chats[1].id, workspaces: [], gridActive: false,
            previous: .chat(chats[2].id))
        XCTAssertEqual(state.tab, .chats)
        XCTAssertEqual(state.chats.selected?.id, chats[1].id, "Start auf dem aktuellen")
        XCTAssertEqual(state.destination, .stay, "Loslassen ohne Bewegung tut nichts")
        XCTAssertTrue(state.isPrevious(chat: chats[2].id), "„vorher“ an der Zeile")
        state.move(1)
        XCTAssertEqual(state.destination, .chat(chats[2].id), "ein Schritt bis zum vorigen")
    }

    /// Start-Reiter: im Raster „Workspaces & Projekte“, in der Einzelansicht
    /// „Chats“ — unabhängig vom vorigen Ort, jeweils auf dem aktuellen Eintrag.
    func testStartTabFollowsTheViewNotThePreviousPlace() {
        let chats = chatRows(2, current: 0)
        let choices = [choice("A"), choice("B")]
        let single = ControllerWhereToState(
            chats: chats, currentChatID: chats[0].id, workspaces: choices, gridActive: false,
            previous: .workspace(choices[1].id))
        XCTAssertEqual(single.tab, .chats)
        XCTAssertEqual(single.destination, .stay)
        XCTAssertTrue(single.isPrevious(choices[1]))

        let current = [choice("A", current: true), choice("B")]
        let grid = ControllerWhereToState(
            chats: chats, currentChatID: chats[0].id, workspaces: current, gridActive: true,
            previous: .chat(chats[1].id))
        XCTAssertEqual(grid.tab, .workspaces)
        XCTAssertEqual(grid.workspaces.selected?.name, "A")
        XCTAssertEqual(grid.destination, .stay)
    }

    /// Ohne angelegten Workspace und ohne Projekt gibt es im Raster nur Chats.
    func testGridWithoutWorkspacesStartsOnChats() {
        let chats = chatRows(2, current: 0)
        let state = ControllerWhereToState(
            chats: chats, currentChatID: chats[0].id, workspaces: [], gridActive: true)
        XCTAssertEqual(state.tab, .chats)
        XCTAssertEqual(state.destination, .stay)
    }

    /// Projekte stehen unter den Workspaces; ein Projekt ist ein eigenes Ziel,
    /// und eine als Workspace gemerkte Projekt-Ansicht trägt „vorher“ an der
    /// Projekt-Zeile.
    func testProjectsAreDestinationsAndMatchTheirViewAsPrevious() {
        let chats = chatRows(1, current: 0)
        let view = UUID()
        var project = choice("WhisperM8")
        project.kind = .project
        project.viewWorkspaceID = view
        let rows = [choice("A", current: true), project]
        var state = ControllerWhereToState(
            chats: chats, currentChatID: chats[0].id, workspaces: rows, gridActive: true,
            previous: .workspace(view))
        XCTAssertEqual(state.previous, .project(project.id))
        XCTAssertTrue(state.isPrevious(project))
        XCTAssertFalse(state.isPrevious(rows[0]))
        state.move(1)
        XCTAssertEqual(state.destination, .project(project.id))
    }

    /// Ein aktuell gezeigtes Projekt ist der aktuelle Eintrag (keine Bewegung,
    /// kein Wechsel).
    func testCurrentProjectViewIsTheCurrentEntry() {
        let chats = chatRows(1, current: 0)
        var project = choice("WhisperM8", current: true)
        project.kind = .project
        let state = ControllerWhereToState(
            chats: chats, currentChatID: chats[0].id, workspaces: [choice("A"), project], gridActive: true)
        XCTAssertEqual(state.workspaces.selected?.id, project.id)
        XCTAssertEqual(state.destination, .stay)
        XCTAssertEqual(state.currentWorkspaceName, "WhisperM8")
    }

    /// Einträge für Projekte: Reihenfolge der Seitenleiste, nur mit aktiven
    /// Chats oder wenn ihr Raster gerade sichtbar ist.
    func testProjectChoicesNeedActiveChatsOrTheirVisibleGrid() {
        let p1 = UUID(), p2 = UUID(), p3 = UUID(), a = UUID(), b = UUID(), view = UUID()
        let choices = ControllerWorkspaceChoice.projectChoices(
            from: [(p1, "Eins", "#111111"), (p2, "Zwei", "#222222"), (p3, "Drei", "#333333")],
            active: [p1: [a, b]], shownProjectID: p3, views: [p1: view],
            status: { $0 == b ? .awaitingInput : .idle })
        XCTAssertEqual(choices.map(\.name), ["Eins", "Drei"])
        XCTAssertEqual(choices.map(\.chatCount), [2, 0])
        XCTAssertEqual(choices.map(\.hasWaitingChat), [true, false])
        XCTAssertEqual(choices.map(\.isCurrent), [false, true])
        XCTAssertEqual(choices.map(\.kind), [.project, .project])
        XCTAssertEqual(choices.first?.viewWorkspaceID, view)
    }

    /// Der vorige Chat kommt in die Liste, wenn die Seitenleiste ihn nicht
    /// zeigt: hinter den aktuellen, ohne aktuellen ganz nach oben.
    func testChatOrderAlwaysContainsThePreviousChat() {
        let a = UUID(), b = UUID(), hidden = UUID()
        XCTAssertEqual(ControllerWhereToState.chatOrder([a, b], current: a, previous: .chat(hidden)), [a, hidden, b])
        XCTAssertEqual(ControllerWhereToState.chatOrder([a, b], current: nil, previous: .chat(hidden)), [hidden, a, b])
        XCTAssertEqual(ControllerWhereToState.chatOrder([a, b], current: a, previous: .chat(b)), [a, b], "schon daneben")
        XCTAssertEqual(ControllerWhereToState.chatOrder([a, b], current: a, previous: .workspace(hidden)), [a, b])
        XCTAssertEqual(ControllerWhereToState.chatOrder([a, b], current: a, previous: .chat(a)), [a, b], "vorher = jetzt")
    }

    /// Review Insel-Paket, Befund 1: Zeigt die Seitenleiste den vorigen Chat
    /// weit weg vom aktuellen, rückt er trotzdem gleich darunter — ein
    /// Schritt, wie Legende und Hilfe es versprechen. Die übrigen Chats
    /// behalten ihre Reihenfolge.
    func testPreviousChatMovesRightBelowTheCurrentEvenWhenFarAway() {
        let ids = (0..<6).map { _ in UUID() }
        XCTAssertEqual(ControllerWhereToState.chatOrder(ids, current: ids[1], previous: .chat(ids[5])),
                       [ids[0], ids[1], ids[5], ids[2], ids[3], ids[4]])
        XCTAssertEqual(ControllerWhereToState.chatOrder(ids, current: ids[4], previous: .chat(ids[0])),
                       [ids[1], ids[2], ids[3], ids[4], ids[0], ids[5]], "auch von oben")

        let chats = chatRows(6, current: 1)
        var state = ControllerWhereToState(
            chats: chats, currentChatID: chats[1].id, workspaces: [], gridActive: false,
            previous: .chat(chats[5].id))
        XCTAssertEqual(state.chats.rows.map(\.id), [chats[0], chats[1], chats[5], chats[2], chats[3], chats[4]].map(\.id))
        XCTAssertEqual(state.destination, .stay)
        state.move(1)
        XCTAssertEqual(state.destination, .chat(chats[5].id), "ein Schritt bis zum vorigen")
    }

    /// Dasselbe im Reiter „Workspaces & Projekte“: Der vorige Ort (hier die
    /// Projekt-Ansicht ganz unten) steht gleich unter dem aktuellen Workspace.
    func testPreviousPlaceMovesRightBelowTheCurrentWorkspace() {
        let view = UUID()
        var project = choice("P")
        project.kind = .project
        project.viewWorkspaceID = view
        let choices = [choice("A", current: true), choice("B"), choice("C"), project]
        var state = ControllerWhereToState(
            chats: chatRows(2, current: 0), currentChatID: nil, workspaces: choices, gridActive: true,
            previous: .workspace(view))
        XCTAssertEqual(state.workspaces.rows.map(\.name), ["A", "P", "B", "C"])
        XCTAssertTrue(state.isPrevious(project))
        state.move(1)
        XCTAssertEqual(state.destination, .project(project.id), "ein Schritt bis zum vorigen")

        let noCurrent = [choice("A"), choice("B"), choice("C")]
        let bare = ControllerWhereToState(
            chats: [], currentChatID: nil, workspaces: noCurrent, gridActive: true,
            previous: .workspace(noCurrent[2].id))
        XCTAssertEqual(bare.workspaces.rows.map(\.name), ["C", "A", "B"], "ohne aktuellen ganz oben")
    }

    /// Ein voriger Ort, der in keiner Liste steht, zählt nicht.
    func testPreviousPlaceOutsideTheListsIsIgnored() {
        let chats = chatRows(2, current: 0)
        let state = ControllerWhereToState(
            chats: chats, currentChatID: chats[0].id, workspaces: [], gridActive: false, previous: .chat(UUID()))
        XCTAssertEqual(state.previous, .stay)
        XCTAssertEqual(state.destination, .stay)
    }

    /// Reiterwechsel: Die Markierung beginnt dort neu auf dem aktuellen
    /// Eintrag. Ohne aktuellen gibt es keine Markierung, Loslassen tut nichts.
    func testSwitchingTabsResetsTheMarkerToCurrent() {
        let chats = chatRows(3, current: 0)
        let choices = [choice("A"), choice("B", current: true), choice("C")]
        var state = ControllerWhereToState(
            chats: chats, currentChatID: chats[0].id, workspaces: choices, gridActive: false,
            previous: .chat(chats[2].id))
        state.move(1)
        XCTAssertEqual(state.destination, .chat(chats[2].id), "der vorige steht gleich unter dem aktuellen")
        XCTAssertTrue(state.switchTab(1))
        XCTAssertEqual(state.workspaces.selected?.name, "B", "Workspaces: der aktuelle")
        XCTAssertEqual(state.destination, .stay)
        state.move(1)
        XCTAssertEqual(state.destination, .workspace(choices[2].id))
        XCTAssertFalse(state.switchTab(1), "kein Umlauf")
        XCTAssertTrue(state.switchTab(-1))
        XCTAssertEqual(state.destination, .stay, "zurück: wieder auf dem aktuellen Chat")

        let noCurrent = [choice("A"), choice("B")]
        var bare = ControllerWhereToState(
            chats: chats, currentChatID: chats[0].id, workspaces: noCurrent, gridActive: false)
        bare.switchTab(1)
        XCTAssertNil(bare.workspaces.selected, "kein Startpunkt: keine Markierung")
        XCTAssertEqual(bare.destination, .stay)
        bare.move(1)
        XCTAssertEqual(bare.destination, .workspace(noCurrent[0].id))
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
