import SwiftUI
import XCTest
@testable import WhisperM8

/// Die Controller-Insel als große Form an der Kamera-Insel: Kacheln in zwei
/// Spalten, die das Steuerkreuz in beide Richtungen abfährt; an Notch und
/// Pille bleibt es die einspaltige Liste mit ◀▶ als Reiterwechsel.
final class ControllerIslandLargeTests: XCTestCase {
    private func chats(_ count: Int) -> [ControllerIslandChatRow] {
        (0..<count).map {
            ControllerIslandChatRow(id: UUID(), title: "Chat \($0)", project: nil, status: .idle, detail: "", isCurrent: $0 == 0)
        }
    }

    private func state(_ count: Int = 8, columns: Int = 2, tickets: Bool = false) -> (ControllerWhereToState, [UUID]) {
        let rows = chats(count)
        let places = [
            ControllerWorkspaceChoice(id: UUID(), name: "A", colorHex: "#000000", chatCount: 1, hasWaitingChat: false, isCurrent: true),
            ControllerWorkspaceChoice(id: UUID(), name: "B", colorHex: "#000000", chatCount: 1, hasWaitingChat: false, isCurrent: false),
        ]
        let boards = tickets ? ControllerTicketBoards(rows: [
            ControllerTicketBoardChoice(id: UUID(), team: "AAA", projectName: "P", colorHex: "#000000", waitingCount: 1, isHere: true, isCurrent: false),
        ]) : nil
        var state = ControllerWhereToState(
            chats: rows, currentChatID: rows.first?.id, workspaces: places, gridActive: false, tickets: boards)
        state.setColumns(columns)
        return (state, rows.map(\.id))
    }

    /// Zwei Spalten: ▼▲ bewegen um eine Reihe in derselben Spalte, ▶◀ zur
    /// Nachbar-Kachel der Reihe.
    func testDpadMovesInBothDirections() {
        var (state, ids) = state()
        XCTAssertEqual(state.columns, 2)
        XCTAssertEqual(state.chats.selected?.id, ids[0])
        XCTAssertTrue(state.moveSideways(1))
        XCTAssertEqual(state.chats.selected?.id, ids[1], "▶: rechte Kachel")
        XCTAssertEqual(state.tab, .chats)
        state.moveRow(1)
        XCTAssertEqual(state.chats.selected?.id, ids[3], "▼: dieselbe Spalte, eine Reihe tiefer")
        XCTAssertTrue(state.moveSideways(-1))
        XCTAssertEqual(state.chats.selected?.id, ids[2])
        state.moveRow(-1)
        XCTAssertEqual(state.chats.selected?.id, ids[0])
        state.moveRow(-1)
        XCTAssertEqual(state.chats.selected?.id, ids[0], "kein Umlauf nach oben")
    }

    /// Am Rand der Reihe wechselt ◀▶ den Reiter, wie bisher; die Markierung
    /// beginnt dort auf dem aktuellen Eintrag.
    func testSidewaysAtTheEdgeSwitchesTheTab() {
        var (state, ids) = state(tickets: true)
        XCTAssertFalse(state.moveSideways(-1), "links von „Chats“ gibt es nichts")
        XCTAssertEqual(state.chats.selected?.id, ids[0])
        state.moveSideways(1)
        XCTAssertEqual(state.tab, .chats)
        XCTAssertTrue(state.moveSideways(1))
        XCTAssertEqual(state.tab, .workspaces, "aus der rechten Spalte: nächster Reiter")
        XCTAssertEqual(state.workspaces.selected?.name, "A")
        XCTAssertEqual(state.columns, 2, "die Spalten bleiben beim Reiterwechsel")
        XCTAssertTrue(state.moveSideways(-1))
        XCTAssertEqual(state.tab, .chats, "aus der linken Spalte ◀: voriger Reiter, ein Druck wie bisher")
        // Ein einzelner Eintrag (Tickets): ▶ aus der linken Spalte ohne Nachbarn wechselt bzw. bleibt.
        state.moveSideways(1); state.moveSideways(1); state.moveSideways(1); state.moveSideways(1)
        XCTAssertEqual(state.tab, .tickets)
        XCTAssertFalse(state.moveSideways(1), "rechts von „Tickets“ gibt es nichts")
    }

    /// Ungerade Zahl: ▼ aus der rechten Spalte in die letzte, halbe Reihe
    /// landet auf ihrem letzten Eintrag; aus der letzten Reihe bleibt ▼ stehen.
    func testOddCountEndsOnTheLastTile() {
        var (state, ids) = state(5)
        state.moveSideways(1)
        state.moveRow(1)
        XCTAssertEqual(state.chats.selected?.id, ids[3])
        state.moveRow(1)
        XCTAssertEqual(state.chats.selected?.id, ids[4], "letzte Reihe hat nur die linke Kachel")
        XCTAssertTrue(state.moveSideways(1), "rechts daneben ist nichts: Reiterwechsel")
        XCTAssertEqual(state.tab, .workspaces)
        var (other, otherIDs) = self.state(5)
        other.moveRow(1); other.moveRow(1)
        XCTAssertEqual(other.chats.selected?.id, otherIDs[4])
        other.moveRow(1)
        XCTAssertEqual(other.chats.selected?.id, otherIDs[4], "kein Umlauf nach unten")
    }

    /// Sichtbar sind drei Reihen; das Fenster rückt reihenweise und beginnt
    /// immer an einem Reihenanfang (die Kacheln springen nicht die Spalte).
    func testWindowScrollsByRows() {
        var (state, ids) = state(11)
        XCTAssertEqual(state.chats.visibleRows.map(\.id), Array(ids[0..<6]))
        state.moveSideways(1)
        for _ in 0..<3 { state.moveRow(1) }
        XCTAssertEqual(state.chats.selected?.id, ids[7])
        XCTAssertEqual(state.chats.visibleRows.first?.id, ids[2], "eine Reihe weiter")
        XCTAssertEqual(state.chats.firstVisibleIndex % 2, 0)
        for _ in 0..<4 { state.moveRow(1) }
        XCTAssertEqual(state.chats.selected?.id, ids[10], "letzte, halbe Reihe")
        XCTAssertEqual(state.chats.firstVisibleIndex % 2, 0)
        XCTAssertTrue(state.chats.visibleRows.contains { $0.id == ids[10] })
        XCTAssertEqual(state.chats.hiddenCount, 11 - state.chats.visibleRows.count)
        for _ in 0..<8 { state.moveRow(-1) }
        XCTAssertEqual(state.chats.firstVisibleIndex, 0)
    }

    /// Tastatur: Tab, ⇧Tab und ↓/↑ gehen in Lesereihenfolge durch die
    /// Kacheln; ←/→ wechseln sofort den Reiter (wie die Fußzeile sagt), auch
    /// aus der linken Spalte, und die Spalten bleiben dabei.
    func testKeyboardStepsInReadingOrderAndArrowsSwitchTabs() {
        var (state, ids) = state()
        state.move(1); state.move(1); state.move(1)
        XCTAssertEqual(state.chats.selected?.id, ids[3])
        state.move(-1)
        XCTAssertEqual(state.chats.selected?.id, ids[2])
        XCTAssertTrue(state.switchTabForKeyboard(1))
        XCTAssertEqual(state.tab, .workspaces, "→ per Tastatur: gleich der Reiter, nicht die Nachbar-Kachel")
        XCTAssertEqual(state.columns, 2)
        XCTAssertTrue(state.switchTabForKeyboard(-1))
        XCTAssertEqual(state.tab, .chats)
    }

    /// An Notch und Pille (eine Spalte) ist alles wie zuvor: ▲▼ ein Eintrag,
    /// ◀▶ sofort der Reiter.
    func testSingleColumnBehavesAsBefore() {
        var (state, ids) = state(columns: 1)
        XCTAssertEqual(state.columns, 1)
        state.moveRow(1)
        XCTAssertEqual(state.chats.selected?.id, ids[1])
        state.moveRow(1)
        XCTAssertEqual(state.chats.selected?.id, ids[2])
        XCTAssertEqual(state.chats.selectedColumn, 0)
        XCTAssertTrue(state.moveSideways(1))
        XCTAssertEqual(state.tab, .workspaces)
        var (fresh, _) = self.state(columns: 1)
        var plain = fresh
        fresh.moveRow(1)
        plain.move(1)
        XCTAssertEqual(fresh, plain)
    }

    /// Zwei Spalten gibt es nur an der Kamera-Insel.
    func testColumnsOnlyAtACameraIsland() {
        let island = NotchScreenInfo(
            displayID: 1, frame: CGRect(x: 0, y: 0, width: 1736, height: 1133),
            visibleFrame: CGRect(x: 0, y: 0, width: 1736, height: 1088),
            safeAreaTop: 40, auxiliaryLeftWidth: 838.5, auxiliaryRightWidth: 838.5, isBuiltIn: true)
        let notch = NotchScreenInfo(
            displayID: 2, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            safeAreaTop: 38, auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5, isBuiltIn: true)
        let plain = NotchScreenInfo(
            displayID: 3, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1415),
            safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, isBuiltIn: false)
        XCTAssertEqual(ControllerIslandGeometry.columns(for: island), 2)
        XCTAssertEqual(ControllerIslandGeometry.columns(for: notch), 1)
        XCTAssertEqual(ControllerIslandGeometry.columns(for: plain), 1)
        XCTAssertEqual(ControllerIslandGeometry.columns(for: nil), 1)

        // Form und Breite: an der Insel die große Form, sonst unverändert.
        let model = ControllerIslandModel(
            target: ControllerIslandTarget(), content: .whereTo(state(columns: 1).0))
        func display(_ screen: NotchScreenInfo) -> ControllerIslandDisplay {
            ControllerIslandDisplay(style: ControllerIslandGeometry.style(for: screen), model: model)
        }
        XCTAssertTrue(display(island).isLarge)
        XCTAssertEqual(display(island).bodyWidth, 460)
        XCTAssertEqual(display(island).bandHeight, 0)
        XCTAssertFalse(display(notch).isLarge)
        XCTAssertEqual(display(notch).bodyWidth, 440)
        XCTAssertEqual(display(notch).bandHeight, 38)
        XCTAssertEqual(display(notch).style, .notch(width: 185, height: 38))
        XCTAssertEqual(display(plain).style, .pill)
        XCTAssertEqual(display(plain).bodyWidth, 440)
    }

    /// Die Kopfzeile lässt Apples Insel so viel Platz, wie die Messung zeigt.
    func testHeaderFollowsTheMeasurement() {
        let island = NotchScreenInfo(
            displayID: 1, frame: CGRect(x: 0, y: 0, width: 1736, height: 1133),
            visibleFrame: CGRect(x: 0, y: 0, width: 1736, height: 1088),
            safeAreaTop: 40, auxiliaryLeftWidth: 838.5, auxiliaryRightWidth: 838.5, isBuiltIn: true)
        var music = NotchMenuBarOccupancy(frames: [])
        music.systemIsland = 802...945
        guard case .island(_, let header) = ControllerIslandGeometry.style(for: island, occupancy: music) else {
            return XCTFail("keine große Form")
        }
        XCTAssertEqual(header.slotLeading, 868 - 802 + 8, accuracy: 0.001)
        XCTAssertEqual(header.slotTrailing, 945 - 868 + 8, accuracy: 0.001)
        XCTAssertEqual(header.height, 42, accuracy: 0.001)
    }
}
