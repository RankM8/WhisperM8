import XCTest
@testable import WhisperM8

/// Diktat an der Kamera-Insel: kompakt in der Menüleiste, Bedienknöpfe nur
/// auf Klick. Geometrie und Platz stehen in `NotchIslandGeometryTests`.
@MainActor
final class IslandDictationCompactTests: XCTestCase {
    private let screen = NotchScreenInfo(
        displayID: 4242, frame: CGRect(x: 0, y: 0, width: 1736, height: 1133),
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
    }

    /// Fällt eine Nachmessung aus, bleibt die Kapsel, wo die letzte gültige
    /// Messung sie hingestellt hat: Sie springt nicht blind über Menüs.
    func testFailedMeasurementKeepsTheLastValidPlace() {
        let controller = controller(capsule: false)
        controller.unifiedScreen = screen
        controller.islandAXTrusted = { true }
        // Menüs reichen links heran: die Kapsel steht rechts.
        let menus = NotchMenuBarOccupancy(frames: [CGRect(x: 10, y: 1088, width: 800, height: 45)])
        controller.refreshIslandCapsule(occupancy: menus, animated: false)
        XCTAssertEqual(controller.islandCapsule?.side, .trailing)
        let placed = controller.islandCapsule
        controller.refreshIslandCapsule(occupancy: nil, animated: false)
        XCTAssertEqual(controller.islandCapsule, placed)
        // Auch die Raute rechnet mit der gemerkten Messung weiter.
        controller.statusBadge = DictationStatusBadge(waiting: 1, errored: 0)
        controller.refreshIslandCapsule(occupancy: nil, animated: false)
        XCTAssertEqual(controller.islandCapsule?.side, .trailing)
    }

    /// Die schmalste Form ohne Messung gibt es nur ohne Berechtigung für
    /// Bedienungshilfen. Mit Berechtigung, aber ohne Messung: keine Kapsel,
    /// das Diktat hängt unter der Menüleiste.
    func testBlindCapsuleOnlyWithoutAccessibilityPermission() {
        let blind = controller(capsule: false)
        blind.unifiedScreen = screen
        blind.islandAXTrusted = { false }
        blind.refreshIslandCapsule(occupancy: nil, animated: false)
        XCTAssertEqual(blind.islandCapsule?.width, NotchIslandGeometry.dictationMinimalWidth)
        XCTAssertTrue(blind.islandControlsShowClock, "die Zeit steht dann bei den Knöpfen")
        blind.statusBadge = DictationStatusBadge(waiting: 1, errored: 0)
        blind.refreshIslandCapsule(occupancy: nil, animated: false)
        XCTAssertEqual(
            blind.islandCapsule?.width,
            NotchIslandGeometry.dictationMinimalWidth + NotchIslandGeometry.dictationBadgeWidth,
            "mit Raute höchstens die Mindestbreite plus das Zeichen")

        let trusted = controller(capsule: false)
        trusted.unifiedScreen = screen
        trusted.islandAXTrusted = { true }
        trusted.refreshIslandCapsule(occupancy: nil, animated: false)
        XCTAssertNil(trusted.islandCapsule)
        XCTAssertFalse(trusted.usesIslandCompact)
    }

    /// Die Zeit ist in jeder Form zu sehen: in der Kapsel, oder aufgeklappt
    /// bei den Knöpfen, wenn die Kapsel nur die Wellenform zeigt.
    func testTimeIsAlwaysShownSomewhere() {
        let compact = controller()
        XCTAssertEqual(compact.islandCapsule?.showsClock, true)
        XCTAssertFalse(compact.islandControlsShowClock)
        let minimal = controller(capsule: false)
        minimal.islandCapsule = NotchIslandGeometry.dictationCapsule(screen: screen, occupancy: nil)
        XCTAssertEqual(minimal.islandCapsule?.showsClock, false)
        XCTAssertTrue(minimal.islandControlsShowClock)
    }

    /// Ein neues Diktat (auch die Übernahme eines Fensters, das sich gerade
    /// zurückzieht) beginnt zugeklappt und ohne den Platz des vorigen.
    func testANewDictationStartsClean() {
        let controller = controller()
        controller.unifiedScreen = screen
        controller.islandAXTrusted = { false }
        controller.isIslandExpanded = true
        controller.islandReserve = (leading: 120, trailing: 120)
        controller.islandOccupancy = NotchMenuBarOccupancy(frames: [])
        controller.islandParts = ["controls": CGRect(x: 0, y: 40, width: 300, height: 40)]
        controller.beginIslandDictation(on: screen)
        XCTAssertFalse(controller.isIslandExpanded)
        XCTAssertTrue(controller.islandParts.isEmpty)
        XCTAssertNil(controller.islandOccupancy)
        XCTAssertEqual(controller.islandCapsule?.width, NotchIslandGeometry.dictationMinimalWidth, "ohne Berechtigung: schmalste Form")
        XCTAssertFalse(controller.islandAwaitsMeasurement)

        // Mit Berechtigung, noch nie gemessen: kurz nur die Insel, keine blinde Kapsel.
        controller.islandAXTrusted = { true }
        controller.beginIslandDictation(on: screen)
        XCTAssertNil(controller.islandCapsule)
        XCTAssertTrue(controller.islandAwaitsMeasurement)
        controller.refreshIslandCapsule(occupancy: NotchMenuBarOccupancy(frames: []), animated: false)
        XCTAssertFalse(controller.islandAwaitsMeasurement)
        XCTAssertEqual(controller.islandCapsule?.showsClock, true)
        controller.tearDownUnified()
    }

    /// Klicks nimmt das Fenster nur auf der Kapsel an, aufgeklappt dazu auf
    /// den Knöpfen: Die Menüleiste zwischen Kapsel und Kamera und auf der
    /// anderen Seite der Insel bleibt bedienbar.
    func testOnlyCapsuleAndControlsTakeClicks() throws {
        let band = NotchIslandGeometry.band(screen: screen)
        let capsule = try XCTUnwrap(NotchIslandGeometry.dictationCapsule(
            screen: screen, occupancy: NotchMenuBarOccupancy(frames: [])))
        let extent = abs(capsule.offset) + capsule.width / 2
        let view = CGRect(x: 304 - extent, y: 0, width: 2 * extent, height: band.capsuleHeight)
        let closed = OverlayController.islandInteractiveParts(
            viewFrame: view, capsule: capsule, band: band, showsControls: false, controls: nil)
        XCTAssertEqual(closed, [CGRect(x: view.minX, y: 0, width: capsule.width, height: 32)])
        XCTAssertFalse(closed.contains { $0.contains(CGPoint(x: view.midX, y: 16)) }, "über der Kamera nichts")
        XCTAssertFalse(closed.contains { $0.contains(CGPoint(x: view.maxX - 10, y: 16)) }, "rechts der Insel nichts")
        XCTAssertFalse(closed.contains { $0.contains(CGPoint(x: view.minX + capsule.width + 10, y: 16)) }, "zwischen Kapsel und Insel nichts")
        // Aufgeklappt: dazu der gemeldete Rahmen der Knöpfe, sonst alles unter der Menüleiste.
        let controls = CGRect(x: 180, y: 42, width: 250, height: 40)
        let open = OverlayController.islandInteractiveParts(
            viewFrame: view.union(controls), capsule: capsule, band: band, showsControls: true, controls: controls)
        XCTAssertEqual(open.count, 2)
        XCTAssertEqual(open.last, controls)
        let fallback = OverlayController.islandInteractiveParts(
            viewFrame: view.union(controls), capsule: capsule, band: band, showsControls: true, controls: nil)
        XCTAssertEqual(fallback.last?.minY, band.neckHeight, "nie in der Menüleiste")
    }
}
