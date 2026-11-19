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
        XCTAssertFalse(controller(capsule: false).usesIslandCompact, "ohne Kapsel (kein Insel-Bildschirm) gilt die Form unter der Menüleiste")
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

    /// Ein normales Diktat steht an der Insel immer in der Menüleiste: Ohne
    /// Messung (keine Berechtigung, Messung gescheitert oder noch nicht da)
    /// die schmalste Form links, nie die Form unter der Menüleiste.
    func testWithoutMeasurementTheNarrowCapsuleStillShows() {
        for trusted in [false, true] {
            let controller = controller(capsule: false)
            controller.unifiedScreen = screen
            controller.islandAXTrusted = { trusted }
            controller.refreshIslandCapsule(occupancy: nil, animated: false)
            XCTAssertEqual(controller.islandCapsule?.width, NotchIslandGeometry.dictationMinimalWidth, "\(trusted)")
            XCTAssertEqual(controller.islandCapsule?.side, .leading)
            XCTAssertEqual(controller.islandCapsule?.isForced, true)
            XCTAssertTrue(controller.usesIslandCompact, "nie unter der Menüleiste")
            XCTAssertTrue(controller.islandControlsShowClock, "die Zeit steht dann bei den Knöpfen")
            controller.statusBadge = DictationStatusBadge(waiting: 1, errored: 0)
            controller.refreshIslandCapsule(occupancy: nil, animated: false)
            XCTAssertEqual(
                controller.islandCapsule?.width,
                NotchIslandGeometry.dictationMinimalWidth + NotchIslandGeometry.dictationBadgeWidth,
                "mit Raute höchstens die Mindestbreite plus das Zeichen")
        }
    }

    /// Auch ohne Platz auf beiden Seiten: die schmalste Form neben der Insel,
    /// nicht die Form unter der Menüleiste.
    func testWithoutRoomTheNarrowCapsuleStillShows() {
        let controller = controller(capsule: false)
        controller.unifiedScreen = screen
        let crowded = NotchMenuBarOccupancy(frames: [
            CGRect(x: 10, y: 1088, width: 800, height: 45), CGRect(x: 930, y: 1088, width: 780, height: 45),
        ])
        controller.refreshIslandCapsule(occupancy: crowded, animated: false)
        XCTAssertEqual(controller.islandCapsule?.isForced, true)
        XCTAssertEqual(controller.islandCapsule?.showsClock, false)
        XCTAssertTrue(controller.usesIslandCompact)
    }

    /// Je Diktat steht einmal im Log, in welcher Form es an der Insel steht
    /// und warum.
    func testDecisionLineNamesFormAndReason() throws {
        func line(_ capsule: NotchIslandDictationCapsule?, _ occupancy: NotchMenuBarOccupancy?,
                  quick: Bool = false, pad: Bool = false, trusted: Bool = true, failure: String? = nil) -> String {
            OverlayController.islandDecisionLine(
                capsule: capsule, occupancy: occupancy, screen: screen, quickAction: quick, controller: pad,
                trusted: trusted, failure: failure)
        }
        let free = NotchMenuBarOccupancy(frames: [])
        let measured = try XCTUnwrap(NotchIslandGeometry.dictationCapsule(screen: screen, occupancy: free))
        XCTAssertEqual(line(measured, free), "island_dictation form=compact side=leading reason=measured free=838/838 system_island=rest")
        let blind = try XCTUnwrap(NotchIslandGeometry.dictationCapsule(screen: screen, occupancy: nil))
        XCTAssertEqual(line(blind, nil, trusted: false), "island_dictation form=minimal side=leading reason=no_accessibility_permission")
        XCTAssertEqual(
            line(blind, nil, failure: "own_menu_bar_unreadable"),
            "island_dictation form=minimal side=leading reason=no_measurement(own_menu_bar_unreadable)")
        XCTAssertEqual(line(blind, nil), "island_dictation form=minimal side=leading reason=no_measurement(pending)")
        var crowded = NotchMenuBarOccupancy(frames: [
            CGRect(x: 10, y: 1088, width: 800, height: 45), CGRect(x: 930, y: 1088, width: 780, height: 45),
        ])
        crowded.systemIsland = 802...945
        let forced = try XCTUnwrap(NotchIslandGeometry.dictationCapsule(screen: screen, occupancy: crowded))
        XCTAssertEqual(line(forced, crowded), "island_dictation form=minimal side=leading reason=no_room free=28/32 system_island=802-945")
        XCTAssertTrue(line(measured, free, quick: true).contains("form=below_menu_bar reason=quick_action"))
        XCTAssertTrue(line(measured, free, pad: true).contains("form=below_menu_bar reason=controller"))
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
        XCTAssertEqual(controller.islandCapsule?.width, NotchIslandGeometry.dictationMinimalWidth, "noch keine Messung: schmalste Form")
        XCTAssertFalse(controller.islandDecisionLogged)

        // Die erste Messung stellt die volle Kapsel hin. Die Log-Zeile kommt
        // erst nach der Frist bzw. am Ende des Diktats, einmal.
        controller.refreshIslandCapsule(occupancy: NotchMenuBarOccupancy(frames: []), animated: false)
        XCTAssertEqual(controller.islandCapsule?.showsClock, true)
        XCTAssertFalse(controller.islandDecisionLogged)
        controller.logIslandDecision()
        XCTAssertTrue(controller.islandDecisionLogged)
        controller.tearDownUnified()
    }

    /// Ein zweites Diktat mit derselben Kapsel (ohne Berechtigung immer, oft
    /// bei gleicher Messung, auch bei Übernahme eines Fensters, das sich
    /// gerade zurückzieht): Die Trefferflächen stehen wieder, das Fenster
    /// nimmt nicht die ganze Ansicht um die Kamera.
    func testSecondDictationWithTheSameCapsuleKeepsItsHitAreas() throws {
        let controller = controller(capsule: false)
        controller.unifiedScreen = screen
        controller.islandAXTrusted = { false }
        controller.islandViewFrame = CGRect(x: 100, y: 0, width: 408, height: 32)
        controller.beginIslandDictation(on: screen)
        let capsule = try XCTUnwrap(controller.islandCapsule)
        XCTAssertEqual(controller.islandInteractiveParts.count, 1)
        let first = controller.islandInteractiveParts
        XCTAssertEqual(first.first?.width, capsule.width)
        // Diktat zu Ende, das nächste beginnt: dieselbe Kapsel, dieselben Flächen.
        controller.tearDownUnified(keepingWindow: true)
        controller.beginIslandDictation(on: screen)
        XCTAssertEqual(controller.islandCapsule, capsule)
        XCTAssertEqual(controller.islandInteractiveParts, first)
        // Im Ruhebild des Übergangs gilt die Ansicht als Ganzes, danach wieder die Kapsel.
        controller.showsRestLook = true
        controller.refreshIslandInteractiveParts()
        XCTAssertTrue(controller.islandInteractiveParts.isEmpty)
        controller.showsRestLook = false
        controller.reportPillFrame(CGRect(x: 100, y: 0, width: 408, height: 32))
        XCTAssertEqual(controller.islandInteractiveParts, first)
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
