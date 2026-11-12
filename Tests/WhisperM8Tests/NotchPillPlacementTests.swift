import CoreGraphics
import XCTest
@testable import WhisperM8

/// Pille ohne Notch: wo die Anzeige steht, gemerkte Lage, Öffnungsrichtung
/// und dass alles auf dem Bildschirm bleibt.
final class NotchPillPlacementTests: XCTestCase {
    /// MacBook mit Notch links, externer Bildschirm ohne Notch rechts.
    private let macBook = NotchScreenInfo(
        displayID: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944), safeAreaTop: 38,
        auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5, isBuiltIn: true, uuid: "MACBOOK")
    private let external = NotchScreenInfo(
        displayID: 2, frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 70, width: 2560, height: 1345), safeAreaTop: 0,
        auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, isBuiltIn: false, uuid: "EXTERNAL")
    private let other = NotchScreenInfo(
        displayID: 3, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055), safeAreaTop: 0,
        auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, isBuiltIn: false)

    private func placements(
        _ choice: NotchScreenChoice = .auto, screens: [NotchScreenInfo]? = nil, main: UInt32 = 2, agent: UInt32?
    ) -> [NotchPlacement] {
        NotchPillPlacement.placements(
            choice: choice, screens: screens ?? [macBook, external], mainDisplayID: main, agentWindowDisplayID: agent)
    }

    // MARK: Wo die Anzeige steht

    /// Agent Chats auf dem externen Bildschirm: Notch am MacBook wie bisher,
    /// dazu die Pille auf dem externen.
    func testAgentWindowOnExternalAddsAPillThere() {
        let result = placements(agent: 2)
        XCTAssertEqual(result.map(\.kind), [.notch, .pill])
        XCTAssertEqual(result.map(\.screen.displayID), [1, 2])
    }

    /// Agent Chats auf dem MacBook: nur die Notch, keine Pille.
    func testAgentWindowAtTheNotchShowsNoPill() {
        XCTAssertEqual(placements(agent: 1).map(\.kind), [.notch])
    }

    /// Kein Agent-Chats-Fenster: wie bisher nur der gewählte Bildschirm.
    func testWithoutAgentWindowOnlyTheChosenScreen() {
        XCTAssertEqual(placements(agent: nil).map(\.kind), [.notch])
        let mainOnly = placements(.main, agent: nil)
        XCTAssertEqual(mainOnly.map(\.kind), [.pill])
        XCTAssertEqual(mainOnly.first?.screen.displayID, 2)
    }

    /// Ohne Notch gehört die Pille dem Bildschirm des Agent-Chats-Fensters,
    /// nicht dem gewählten — nie zwei Pillen.
    func testPillFollowsTheAgentWindowOnMacsWithoutNotch() {
        let result = placements(.main, screens: [external, other], main: 2, agent: 3)
        XCTAssertEqual(result.map(\.kind), [.pill])
        XCTAssertEqual(result.first?.screen.displayID, 3)
    }

    /// „Hauptbildschirm“ gewählt (extern), Agent Chats am MacBook: die Pille
    /// steht auf dem gewählten Bildschirm, an der Notch nichts.
    func testMainChoiceWithAgentWindowAtTheNotch() {
        let result = placements(.main, agent: 1)
        XCTAssertEqual(result.map(\.kind), [.pill])
        XCTAssertEqual(result.first?.screen.displayID, 2)
    }

    func testNoScreensNoPlacements() {
        XCTAssertTrue(placements(screens: [], agent: nil).isEmpty)
    }

    // MARK: Lage

    func testDefaultCenterIsTopCenterBelowTheMenuBar() {
        let center = NotchPillPlacement.center(external, stored: nil)
        XCTAssertEqual(center.x, external.frame.midX, accuracy: 0.001)
        XCTAssertEqual(center.y + NotchGeometry.pillHeight / 2, 1440 - 25 - NotchGeometry.pillTopGap, accuracy: 0.001)
        XCTAssertFalse(NotchPillPlacement.opensUpward(center: center, on: external))
    }

    /// Gemerkt als Anteil am Bildschirm: Hin und zurück ergibt dieselbe Stelle.
    func testStoredPositionRoundTrips() {
        let point = CGPoint(x: 1512 + 400, y: 300)
        let stored = NotchPillPlacement.position(forCenter: point, on: external)
        let center = NotchPillPlacement.center(external, stored: stored)
        XCTAssertEqual(center.x, point.x, accuracy: 0.001)
        XCTAssertEqual(center.y, point.y, accuracy: 0.001)
    }

    /// Eine gemerkte Lage außerhalb (anderer Bildschirm, Dock, Menüleiste)
    /// wird in den sichtbaren Bereich geholt.
    func testStoredPositionIsClampedToTheVisibleArea() {
        for stored in [NotchPillPosition(x: -1, y: 2), NotchPillPosition(x: 2, y: -1), NotchPillPosition(x: 0.5, y: 1)] {
            let center = NotchPillPlacement.center(external, stored: stored)
            let pill = CGRect(x: center.x - NotchGeometry.pillIdleWidth / 2, y: center.y - NotchGeometry.pillHeight / 2,
                              width: NotchGeometry.pillIdleWidth, height: NotchGeometry.pillHeight)
            XCTAssertTrue(external.visibleFrame.insetBy(dx: -0.001, dy: -0.001).contains(pill), "\(stored)")
        }
    }

    /// In der oberen Hälfte wächst alles nach unten (Oberkante der Pille
    /// bleibt), in der unteren nach oben (Unterkante bleibt).
    func testGrowsDownwardInTheUpperHalfAndUpwardInTheLowerHalf() {
        let size = CGSize(width: 440, height: 300)
        let high = CGPoint(x: 2800, y: 1000)
        let down = NotchPillPlacement.frame(size: size, growingFrom: high, on: external)
        XCTAssertEqual(down.maxY, high.y + NotchGeometry.pillHeight / 2, accuracy: 0.001)
        XCTAssertEqual(down.midX, high.x, accuracy: 0.001)

        let low = CGPoint(x: 2800, y: 300)
        XCTAssertTrue(NotchPillPlacement.opensUpward(center: low, on: external))
        let up = NotchPillPlacement.frame(size: size, growingFrom: low, on: external)
        XCTAssertEqual(up.minY, low.y - NotchGeometry.pillHeight / 2, accuracy: 0.001)
    }

    /// Nahe am Rand wird verschoben, nie abgeschnitten.
    func testGrownFrameStaysOnScreen() {
        let size = CGSize(width: 440, height: 500)
        let corners = [CGPoint(x: 1530, y: 1400), CGPoint(x: 4060, y: 1400), CGPoint(x: 1530, y: 90), CGPoint(x: 4060, y: 90),
                       CGPoint(x: 2800, y: 760)]
        for corner in corners {
            let frame = NotchPillPlacement.frame(size: size, growingFrom: corner, on: external)
            XCTAssertTrue(external.visibleFrame.insetBy(dx: -0.001, dy: -0.001).contains(frame), "\(corner)")
        }
    }

    /// Die Anzeige liegt an der gemerkten Stelle; ihre Liste öffnet in der
    /// unteren Hälfte nach oben.
    func testNotchLayoutUsesThePillCenter() {
        let low = CGPoint(x: 2000, y: 400)
        let compact = NotchGeometry.panelFrame(screen: external, mode: .compact(chipCount: 2), pillCenter: low)
        XCTAssertEqual(compact.midX, low.x, accuracy: 0.001)
        XCTAssertEqual(compact.midY, low.y, accuracy: 0.001)
        let expanded = NotchGeometry.panelFrame(
            screen: external, mode: .expanded(rowCount: 3, sectionCount: 2), pillCenter: low)
        XCTAssertEqual(expanded.minY, compact.minY, accuracy: 0.001, "nach oben: Unterkante bleibt")
        XCTAssertGreaterThan(expanded.height, compact.height)
    }

    /// Die Controller-Insel wächst aus derselben Stelle wie die Pille.
    func testIslandGrowsOutOfThePill() {
        let stored = NotchPillPlacement.position(forCenter: CGPoint(x: 2000, y: 400), on: external)
        let island = ControllerIslandGeometry.frame(screen: external, bodySize: CGSize(width: 440, height: 320), stored: stored)
        let pill = NotchGeometry.panelFrame(
            screen: external, mode: .compact(chipCount: 1), pillCenter: NotchPillPlacement.center(external, stored: stored))
        XCTAssertEqual(island.midX, pill.midX, accuracy: 0.001)
        XCTAssertEqual(island.minY, pill.minY, accuracy: 0.001, "untere Hälfte: nach oben, gemeinsame Unterkante")
        XCTAssertTrue(ControllerIslandGeometry.opensUpward(screen: external, stored: stored))
        XCTAssertFalse(ControllerIslandGeometry.opensUpward(screen: macBook, stored: stored), "an der Notch nie")

        let top = ControllerIslandGeometry.frame(screen: external, bodySize: CGSize(width: 440, height: 320))
        let defaultPill = NotchGeometry.panelFrame(screen: external, mode: .compact(chipCount: 1))
        XCTAssertEqual(top.maxY, defaultPill.maxY, accuracy: 0.001, "oben mittig: gemeinsame Oberkante")
        let panel = ControllerIslandGeometry.panelFrame(screen: external, bodySize: CGSize(width: 440, height: 320))
        XCTAssertEqual(panel, top.insetBy(dx: -ControllerIslandGeometry.shadowMargin, dy: -ControllerIslandGeometry.shadowMargin))
    }

    /// Schlüssel der gemerkten Lage ist die feste UUID, nicht die Nummer.
    func testStorageKeyIsTheDisplayUUID() {
        XCTAssertEqual(external.pillStorageKey, "EXTERNAL")
        XCTAssertEqual(other.pillStorageKey, "display-3")
    }

    @MainActor
    func testPositionsArePersistedPerScreenAndCanBeReset() {
        let name = "notch-pill-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = AppPreferences(defaults: defaults)
        XCTAssertTrue(prefs.notchPillPositions.isEmpty)
        prefs.notchPillPositions = ["EXTERNAL": NotchPillPosition(x: 0.2, y: 0.3)]
        XCTAssertEqual(prefs.notchPillPositions["EXTERNAL"], NotchPillPosition(x: 0.2, y: 0.3))
        XCTAssertEqual(NotchConfig.current(prefs).pillPositions.count, 1)
        prefs.notchPillPositions = [:]
        XCTAssertNil(defaults.object(forKey: PreferenceKeys.notchPillPositions))
    }
}
