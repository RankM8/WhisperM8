import XCTest
@testable import WhisperM8

/// Messung der Menüleiste neben einer Kamera-Insel, mit einer Attrappe der
/// Accessibility-Schicht. Aufbau wie am 18.11.2026 unter macOS 27.2.1
/// gemessen: Ein Prozess führt das bildschirmgroße Fenster der Insel und das
/// Fenster der Menüleiste mit den Statussymbolen.
final class NotchIslandProbeTests: XCTestCase {
    private final class Node {
        var frame: CGRect?
        var children: [Node]
        init(_ frame: CGRect?, _ children: [Node] = []) {
            self.frame = frame
            self.children = children
        }
    }

    private let screen = NotchScreenInfo(
        displayID: 1, frame: CGRect(x: 0, y: 0, width: 1736, height: 1133),
        visibleFrame: CGRect(x: 0, y: 0, width: 1736, height: 1088),
        safeAreaTop: 40, auxiliaryLeftWidth: 838.5, auxiliaryRightWidth: 838.5, isBuiltIn: true)
    private let islandPID: pid_t = 50
    private let frontPID: pid_t = 60
    private let ownPID: pid_t = 70

    /// Fensterliste von vorn nach hinten: Mauszeiger, Insel, eigenes Fenster, Menüleiste.
    private var windows: [NotchWindowSample] {
        [
            NotchWindowSample(layer: 2_147_483_630, bounds: CGRect(x: 860, y: 12, width: 28, height: 28), ownerPID: 1),
            NotchWindowSample(layer: 26, bounds: CGRect(x: 0, y: 0, width: 1736, height: 1133), ownerPID: islandPID),
            NotchWindowSample(layer: 27, bounds: CGRect(x: 0, y: 0, width: 1736, height: 64), ownerPID: ownPID),
            NotchWindowSample(layer: 24, bounds: CGRect(x: 0, y: 0, width: 1736, height: 45), ownerPID: 1),
            NotchWindowSample(layer: 0, bounds: CGRect(x: 0, y: 45, width: 1736, height: 1088), ownerPID: frontPID),
        ]
    }

    private func item(_ minX: CGFloat, _ width: CGFloat) -> Node {
        Node(CGRect(x: minX, y: 0, width: width, height: 45))
    }

    /// Attrappe: merkt sich, welche Prozesse gefragt wurden.
    private func ax(
        activity: CGRect? = nil, statusBar: Bool = true, trusted: Bool = true, asked: UnsafeMutablePointer<[pid_t]>? = nil
    ) -> NotchIslandAX {
        let hud = Node(CGRect(x: 0, y: 0, width: 1736, height: 1133), activity.map { [Node($0)] } ?? [])
        let bar = Node(CGRect(x: 0, y: 0, width: 1736, height: 45), [item(1151, 34), item(1600, 115.5), Node(nil)])
        let menus = Node(CGRect(x: 0, y: 0, width: 1736, height: 45), [item(10, 34), item(44, 90), item(467, 48)])
        let islandPID = islandPID, frontPID = frontPID
        return NotchIslandAX(
            isTrusted: { trusted },
            windows: { pid in
                asked?.pointee.append(pid)
                return pid == islandPID ? (statusBar ? [hud, bar] : [hud]) : nil
            },
            menuBar: { pid in
                asked?.pointee.append(pid)
                return pid == frontPID ? menus : nil
            },
            children: { ($0 as? Node)?.children },
            frame: { ($0 as? Node)?.frame })
    }

    private func measure(_ ax: NotchIslandAX, windows: [NotchWindowSample]? = nil, menuOwner: pid_t? = 60) -> NotchMenuBarOccupancy? {
        NotchIslandProbe.measure(
            screen: screen, primaryHeight: 1133, menuOwnerPID: menuOwner, ownPID: ownPID,
            windows: windows ?? self.windows, ax: ax)
    }

    /// Menüs und Statussymbole als Rahmen in Cocoa-Koordinaten; in Ruhe
    /// meldet die Insel nichts.
    func testMeasuresMenusAndStatusItems() throws {
        let occupancy = try XCTUnwrap(measure(ax()))
        XCTAssertNil(occupancy.systemIsland)
        XCTAssertEqual(occupancy.frames.count, 5)
        XCTAssertTrue(occupancy.frames.contains(CGRect(x: 467, y: 1133 - 45, width: 48, height: 45)))
        XCTAssertTrue(occupancy.frames.contains(CGRect(x: 1151, y: 1133 - 45, width: 34, height: 45)))
        let free = NotchIslandGeometry.freeSpace(screen: screen, occupancy: occupancy)
        XCTAssertEqual(free.leading, 838.5 - 515)
        XCTAssertEqual(free.trailing, 1151 - 897.5)
    }

    /// Zeigt Apples Insel etwas, hat ihr Fenster ein Kind mit dem Rahmen der Kapsel.
    func testReadsWhatTheSystemIslandShows() throws {
        let occupancy = try XCTUnwrap(measure(ax(activity: CGRect(x: 802, y: 6, width: 143, height: 34))))
        XCTAssertEqual(occupancy.systemIsland, 802...945)
        XCTAssertEqual(occupancy.systemIslandInsets, 6...40)
    }

    /// Der Prozess der Insel kommt aus der Fensterliste: Besitzer des
    /// obersten bildschirmbreiten Fensters an der Kamera. Der Mauszeiger über
    /// der Kamera und das eigene Fenster zählen nicht. Gefragt werden nur
    /// dieser Prozess und die vordere App, nie ein systemweites Element.
    func testIslandOwnerComesFromTheWindowList() throws {
        let candidates = NotchIslandProbe.islandOwnerCandidates(
            windows: windows, camera: CGPoint(x: 868, y: 24),
            screenQuartz: CGRect(x: 0, y: 0, width: 1736, height: 1133), ownPID: ownPID)
        XCTAssertEqual(candidates, [islandPID, 1])
        var asked: [pid_t] = []
        XCTAssertNotNil(measure(ax(asked: &asked)))
        XCTAssertEqual(Set(asked), [islandPID, frontPID])
    }

    /// Die Messung selbst erzeugt kein systemweites Accessibility-Element:
    /// Ein Zeitlimit daran gälte für alle Aufrufe der App, auch für den
    /// Diktat-Kontext (`SelectedContextService`).
    func testProbeNeverUsesTheSystemWideElement() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["NotchIslandProbe.swift", "NotchStatusController+Placements.swift"] {
            let text = try String(
                contentsOf: root.appendingPathComponent("WhisperM8/Services/AgentChats/Notch/\(file)"), encoding: .utf8)
            XCTAssertFalse(text.contains("AXUIElementCreateSystemWide"), file)
            XCTAssertFalse(text.contains("AXUIElementCopyElementAtPosition"), file)
        }
    }

    /// Ohne Berechtigung, ohne vordere App, ohne Fenster der Insel an der
    /// Kamera oder ohne Fenster der Menüleiste: kein Ergebnis, die Anzeige
    /// bleibt aus der Menüleiste heraus.
    func testNoResultWithoutAllParts() {
        XCTAssertNil(measure(ax(trusted: false)))
        XCTAssertNil(measure(ax(), menuOwner: nil))
        XCTAssertNil(measure(ax(statusBar: false)))
        XCTAssertNil(measure(ax(), windows: windows.filter { $0.ownerPID != islandPID }))
        XCTAssertNil(measure(ax(), menuOwner: 61), "die vordere App meldet keine Menüleiste")
        // Notch und Bildschirm ohne Aussparung werden nicht gemessen.
        var notch = screen
        notch.auxiliaryLeftWidth = 775
        notch.auxiliaryRightWidth = 775
        XCTAssertNil(NotchIslandProbe.measure(
            screen: notch, primaryHeight: 1133, menuOwnerPID: frontPID, ownPID: ownPID, windows: windows, ax: ax()))
    }

    /// Nach der Gesamtfrist antwortet die echte Schicht nicht mehr.
    func testLiveLayerStopsAfterTheDeadline() {
        let expired = NotchIslandAX.live(deadline: Date().addingTimeInterval(-1))
        XCTAssertNil(expired.windows(ProcessInfo.processInfo.processIdentifier))
        XCTAssertNil(expired.menuBar(ProcessInfo.processInfo.processIdentifier))
        XCTAssertEqual(NotchIslandProbe.budget, 0.5)
    }

    /// VoiceOver: Die Anzeige nennt in Ruhe, was Zeichen und Zahl bedeuten.
    func testAccessibilitySummaryNamesTheState() {
        let display = NotchDisplay(
            style: .pill, summary: NotchSummary(working: 2, waiting: 1), alert: nil, isExpanded: false, sections: [])
        XCTAssertEqual(
            display.accessibilitySummary,
            [String(localized: "\(2) working"), String(localized: "\(1) waiting for you")].joined(separator: ", "))
        let idle = NotchDisplay(style: .pill, summary: .empty, alert: nil, isExpanded: false, sections: [])
        XCTAssertEqual(idle.accessibilitySummary, String(localized: "No active chats"))
    }
}
