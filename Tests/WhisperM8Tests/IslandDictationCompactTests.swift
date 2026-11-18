import XCTest
@testable import WhisperM8

/// Diktat an der Kamera-Insel: kompakt in der Menüleiste, Bedienknöpfe nur
/// auf Klick. Geometrie und Platz stehen in `NotchIslandGeometryTests`.
@MainActor
final class IslandDictationCompactTests: XCTestCase {
    private let screen = NotchScreenInfo(
        displayID: 1, frame: CGRect(x: 0, y: 0, width: 1736, height: 1133),
        visibleFrame: CGRect(x: 0, y: 0, width: 1736, height: 1088),
        safeAreaTop: 40, auxiliaryLeftWidth: 838.5, auxiliaryRightWidth: 838.5, isBuiltIn: true)

    private func controller(capsule: Bool = true) -> OverlayController {
        let controller = OverlayController(presentsWindow: false)
        controller.presentation = .island(NotchIslandGeometry.band(screen: screen))
        if capsule {
            controller.islandCapsule = NotchIslandGeometry.dictationCapsule(
                screen: screen, occupancy: NotchMenuBarOccupancy(frames: []))
        }
        return controller
    }

    /// Kompakt nur an der Insel und nur, wenn die Geometrie eine Kapsel
    /// hergibt; Notch und Pille bleiben, wie sie waren.
    func testCompactOnlyAtTheIslandWithRoom() {
        XCTAssertTrue(controller().usesIslandCompact)
        XCTAssertFalse(controller(capsule: false).usesIslandCompact, "kein Platz: Ausweichform unter der Menüleiste")
        let notch = controller()
        notch.presentation = .notch(width: 185, height: 38)
        XCTAssertFalse(notch.usesIslandCompact)
        let pill = controller()
        pill.presentation = .pill
        XCTAssertFalse(pill.usesIslandCompact)
    }

    /// Schnellaktion (Beschriftung) und Aufnahme per Controller (Ziel und
    /// Modus ohne Klick sichtbar) hängen weiter unter der Menüleiste.
    func testQuickActionAndControllerStayBelowTheMenuBar() {
        let quick = controller()
        quick.quickActionLabel = "Correct"
        XCTAssertFalse(quick.usesIslandCompact)
        let pad = controller()
        pad.controllerTargetLabel = "Release-Notizen"
        XCTAssertFalse(pad.usesIslandCompact)
    }

    /// Die Bedienknöpfe erscheinen nur auf Klick, und solange ein
    /// Bildschirm-Clip läuft (sein Stopp-Knopf bleibt erreichbar).
    func testControlsOnlyOnClick() {
        let controller = controller()
        XCTAssertFalse(controller.showsIslandControls)
        controller.toggleIslandExpanded()
        XCTAssertTrue(controller.showsIslandControls)
        controller.toggleIslandExpanded()
        XCTAssertFalse(controller.showsIslandControls)
        controller.isScreenClipRecording = true
        XCTAssertTrue(controller.showsIslandControls)
    }

    /// Im Diktat rückt die Kapsel nur nach außen: Der Platz für Apples Insel
    /// wächst mit der Messung, schrumpft aber nicht zurück.
    func testCapsuleKeepsItsPlaceDuringADictation() {
        let controller = controller(capsule: false)
        controller.unifiedScreen = screen
        var occupancy = NotchMenuBarOccupancy(frames: [])
        controller.refreshIslandCapsule(occupancy: occupancy, animated: false)
        let start = controller.islandCapsule
        XCTAssertEqual(start?.side, .leading)
        XCTAssertEqual(start?.showsClock, true)
        // Mikrofon-Punkt, dann mit Mikrofon-Zeichen, dann wieder der Punkt: links bleibt alles stehen.
        for system in [812...923.5, 802...945, 812...923.5] as [ClosedRange<CGFloat>] {
            occupancy.systemIsland = system
            controller.refreshIslandCapsule(occupancy: occupancy, animated: false)
            XCTAssertEqual(controller.islandCapsule, start)
        }
        // Eine größere Live Activity verdeckte Inhalt: nach außen, und dort bleibt sie.
        occupancy.systemIsland = 760...960
        controller.refreshIslandCapsule(occupancy: occupancy, animated: false)
        let moved = controller.islandCapsule
        XCTAssertLessThan(moved?.offset ?? 0, start?.offset ?? 0)
        occupancy.systemIsland = nil
        controller.refreshIslandCapsule(occupancy: occupancy, animated: false)
        XCTAssertEqual(controller.islandCapsule, moved)
        // Ohne Messung: die schmalste Form.
        let blind = self.controller(capsule: false)
        blind.unifiedScreen = screen
        blind.refreshIslandCapsule(occupancy: nil, animated: false)
        XCTAssertEqual(blind.islandCapsule?.width, NotchIslandGeometry.dictationMinimalWidth)
    }
}
