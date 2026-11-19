import SwiftUI
import XCTest
@testable import WhisperM8

/// Diktat an der Kamera-Insel: kompakt in der Menüleiste, Bedienknöpfe nur
/// auf Klick, dann als große Form um die Kamera. Geometrie und Platz stehen
/// in `NotchIslandGeometryTests` und `NotchIslandLargeGeometryTests`.
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
            controller.islandDictationForm = NotchIslandLargeGeometry.form(screen: screen, kind: .dictation)
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

    /// Die große Form mit den Bedienknöpfen geht nur auf Klick auf, nie von
    /// selbst (sie verdeckt Menüs neben der Kamera): auch nicht, solange ein
    /// Bildschirm-Clip läuft. Wer einen Clip startet, will den Bildschirm
    /// zeigen; die Form geht dafür zu, ein Klick auf die Kapsel öffnet sie
    /// wieder zum Stoppen.
    func testLargeFormOnlyOnClick() {
        let controller = controller()
        XCTAssertFalse(controller.showsIslandLargeForm)
        controller.toggleIslandExpanded()
        XCTAssertTrue(controller.showsIslandLargeForm)
        controller.toggleIslandExpanded()
        XCTAssertFalse(controller.showsIslandLargeForm)
        controller.isScreenClipRecording = true
        XCTAssertFalse(controller.showsIslandLargeForm, "ein laufender Clip klappt nichts auf")

        controller.isScreenClipRecording = false
        controller.toggleIslandExpanded()
        controller.toggleScreenClip()
        XCTAssertFalse(controller.isIslandExpanded, "Clip gestartet: die Form geht zu")
        // Zum Stoppen aufgeklappt bleibt sie offen.
        controller.isScreenClipRecording = true
        controller.toggleIslandExpanded()
        controller.toggleScreenClip()
        XCTAssertTrue(controller.isIslandExpanded)
        controller.tearDownUnified()
        XCTAssertFalse(controller.isIslandExpanded, "mit dem Diktat geht auch die Form zu")
    }

    /// Auch ein Bildschirmfoto klappt die Form vor der Auswahl zu, damit
    /// sie nicht im Bild steht.
    func testScreenshotClosesTheLargeForm() {
        let controller = controller()
        controller.toggleIslandExpanded()
        XCTAssertTrue(controller.showsIslandLargeForm)
        controller.captureScreenshot()
        XCTAssertFalse(controller.isIslandExpanded)
    }

    /// Dem Mauszeiger folgt das Fenster nur über der Kapsel bzw. der offenen
    /// Form, nicht über der ganzen Ansicht um die Kamera: Fahren durch die
    /// Menüleiste wertet die Pille nicht neu aus.
    func testHoverAreaIsTheCapsuleOrTheOpenForm() throws {
        let controller = controller(capsule: false)
        controller.unifiedScreen = screen
        controller.islandAXTrusted = { false }
        XCTAssertNil(controller.islandHoverFrame)
        controller.islandViewFrame = CGRect(x: 94, y: 0, width: 420, height: 34)
        controller.beginIslandDictation(on: screen)
        let capsule = try XCTUnwrap(controller.islandCapsule)
        XCTAssertEqual(
            controller.islandHoverFrame,
            CGRect(x: 304 + capsule.offset - capsule.width / 2, y: 2, width: capsule.width, height: 32))
        controller.toggleIslandExpanded()
        XCTAssertEqual(controller.islandHoverFrame, CGRect(x: 94, y: 0, width: 420, height: 178))
        controller.toggleIslandExpanded()
        XCTAssertEqual(controller.islandHoverFrame?.width, capsule.width)
        // Ruhebild, Schnellaktion: wieder die Ansicht als Ganzes.
        controller.quickActionLabel = "Correct"
        controller.refreshIslandInteractiveParts()
        XCTAssertNil(controller.islandHoverFrame)
        controller.tearDownUnified()
    }

    /// Schnellaktion und Aufnahme per Controller haben keine große Form,
    /// ebenso wenig ein Diktat ohne Maße dafür.
    func testNoLargeFormOutsideTheCompactDictation() {
        let quick = controller()
        quick.isIslandExpanded = true
        XCTAssertTrue(quick.showsIslandLargeForm)
        quick.quickActionLabel = "Correct"
        XCTAssertFalse(quick.showsIslandLargeForm)
        let bare = controller()
        bare.islandDictationForm = nil
        bare.isIslandExpanded = true
        XCTAssertFalse(bare.showsIslandLargeForm)
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
            XCTAssertNotNil(controller.islandDictationForm, "aufklappen geht auch ohne Messung")
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

    /// Die Zeit ist immer erreichbar: in der Kapsel, wenn Platz ist; die
    /// schmale Kapsel zeigt nur die Wellenform, die große Form zeigt die
    /// Zeit immer. Ihre Kopfzeile lässt Apples Mikrofon-Hinweis denselben
    /// Platz wie die Kapsel, auch wenn die Messung eine breitere Insel zeigt.
    func testLargeFormFollowsTheMeasurement() {
        let controller = controller(capsule: false)
        controller.unifiedScreen = screen
        controller.refreshIslandCapsule(occupancy: nil, animated: false)
        XCTAssertEqual(controller.islandCapsule?.showsClock, false)
        let blind = try? XCTUnwrap(controller.islandDictationForm)
        XCTAssertEqual(blind?.frame.size, CGSize(width: 420, height: 178))
        XCTAssertEqual(blind?.slotTrailing ?? 0, 29.5 + 47.5 + 8, accuracy: 0.001)

        var occupancy = NotchMenuBarOccupancy(frames: [])
        occupancy.systemIsland = 760...960
        controller.refreshIslandCapsule(occupancy: occupancy, animated: false)
        XCTAssertEqual(controller.islandCapsule?.showsClock, true)
        XCTAssertEqual(controller.islandDictationForm?.slotLeading ?? 0, 868 - 760 + 8, accuracy: 0.001)
        XCTAssertEqual(controller.islandDictationForm?.slotTrailing ?? 0, 960 - 868 + 8, accuracy: 0.001)
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
        controller.beginIslandDictation(on: screen)
        XCTAssertFalse(controller.isIslandExpanded)
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
        controller.islandViewFrame = CGRect(x: 94, y: 0, width: 420, height: 34)
        controller.beginIslandDictation(on: screen)
        let capsule = try XCTUnwrap(controller.islandCapsule)
        XCTAssertEqual(controller.islandInteractiveParts.count, 1)
        let first = controller.islandInteractiveParts
        XCTAssertEqual(first.first?.width, capsule.width)
        XCTAssertEqual(first.first?.minY, 2, "die Kapsel sitzt 2 pt unter der Oberkante des Fensters")
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
        controller.reportPillFrame(CGRect(x: 94, y: 0, width: 420, height: 34))
        XCTAssertEqual(controller.islandInteractiveParts, first)
        // Aufgeklappt zählt die große Form, zugeklappt sofort wieder nur die Kapsel.
        controller.toggleIslandExpanded()
        XCTAssertEqual(controller.islandInteractiveParts, [CGRect(x: 94, y: 0, width: 420, height: 178)])
        controller.toggleIslandExpanded()
        XCTAssertEqual(controller.islandInteractiveParts, first)
        controller.tearDownUnified()
    }

    /// Zugeklappt nimmt das Fenster Klicks nur auf der Kapsel an: Die
    /// Menüleiste zwischen Kapsel und Kamera, auf der anderen Seite der
    /// Insel und alles unter der Menüleiste bleibt bedienbar. Aufgeklappt
    /// zählt genau die große Form um die Kamera.
    func testOnlyCapsuleOrTheOpenFormTakesClicks() throws {
        let band = NotchIslandGeometry.band(screen: screen)
        XCTAssertEqual(band.topGap, 2)
        let capsule = try XCTUnwrap(NotchIslandGeometry.dictationCapsule(
            screen: screen, occupancy: NotchMenuBarOccupancy(frames: [])))
        let form = NotchIslandLargeGeometry.form(screen: screen, kind: .dictation)
        let extent = max(abs(capsule.offset) + capsule.width / 2, form.size.width / 2)
        // Die Ansicht beginnt an der Oberkante der großen Form.
        let view = CGRect(x: 304 - extent, y: 0, width: 2 * extent, height: band.topGap + band.capsuleHeight)
        let closed = OverlayController.islandInteractiveParts(viewFrame: view, capsule: capsule, band: band, openForm: nil)
        XCTAssertEqual(closed, [CGRect(x: 304 + capsule.offset - capsule.width / 2, y: 2, width: capsule.width, height: 32)])
        XCTAssertFalse(closed.contains { $0.contains(CGPoint(x: view.midX, y: 16)) }, "über der Kamera nichts")
        XCTAssertFalse(closed.contains { $0.contains(CGPoint(x: view.maxX - 10, y: 16)) }, "rechts der Insel nichts")
        XCTAssertFalse(closed.contains { $0.contains(CGPoint(x: closed[0].maxX + 10, y: 16)) }, "zwischen Kapsel und Insel nichts")
        XCTAssertFalse(closed.contains { $0.contains(CGPoint(x: closed[0].midX, y: 60)) }, "unter der Menüleiste nichts")

        var tall = view
        tall.size.height = form.size.height
        let open = OverlayController.islandInteractiveParts(
            viewFrame: tall, capsule: capsule, band: band, openForm: form.size)
        XCTAssertEqual(open, [CGRect(x: 304 - 210, y: 0, width: 420, height: 178)])
    }

    /// Die Ansicht des Diktat-Fensters hält sich an diese Flächen: Sind sie
    /// gesetzt, zählen allein sie.
    func testHostingViewUsesTheParts() {
        let host = PillHitTestHostingView(rootView: Color.black)
        host.frame = CGRect(x: 0, y: 0, width: 608, height: 194)
        func point(_ x: CGFloat, fromTop y: CGFloat) -> CGPoint { CGPoint(x: x, y: host.isFlipped ? y : 194 - y) }
        host.setInteractive(swiftUIFrame: CGRect(x: 94, y: 0, width: 420, height: 34))
        host.setInteractiveParts(swiftUIFrames: [CGRect(x: 136, y: 2, width: 96, height: 32)])
        XCTAssertTrue(host.takesClick(at: point(180, fromTop: 18)))
        XCTAssertFalse(host.takesClick(at: point(304, fromTop: 18)), "über der Kamera")
        XCTAssertFalse(host.takesClick(at: point(450, fromTop: 18)), "rechts der Insel")
        XCTAssertNil(host.hitTest(point(450, fromTop: 18)))
        // Aufgeklappt: die ganze Form, nicht mehr.
        host.setInteractiveParts(swiftUIFrames: [CGRect(x: 94, y: 0, width: 420, height: 178)])
        XCTAssertTrue(host.takesClick(at: point(304, fromTop: 120)))
        XCTAssertFalse(host.takesClick(at: point(60, fromTop: 120)))
        XCTAssertFalse(host.takesClick(at: point(304, fromTop: 190)))
        // Ohne Teilflächen gilt die ganze Pille wie bisher.
        host.setInteractiveParts(swiftUIFrames: [])
        XCTAssertTrue(host.takesClick(at: point(304, fromTop: 18)))
        XCTAssertFalse(host.takesClick(at: point(304, fromTop: 120)))
        // Ruhebild ohne Zeile (das Diktat zieht sich zurück): keine Fläche,
        // auch nicht die der eben noch offenen Form.
        host.setInteractive(swiftUIFrame: CGRect(x: 94, y: 0, width: 420, height: 178))
        XCTAssertTrue(host.takesClick(at: point(304, fromTop: 120)))
        host.setInteractive(swiftUIFrame: .zero)
        for spot in [point(304, fromTop: 120), point(304, fromTop: 18), point(1, fromTop: 1), point(0, fromTop: 0)] {
            XCTAssertFalse(host.takesClick(at: spot))
        }
    }

    /// Ein Klick neben die offene große Form schließt sie: in ein normales
    /// eigenes Fenster ja, ins Fenster des Diktats und in schwebende Fenster
    /// (die Menüs der Form selbst) nicht.
    func testOnlyClicksInNormalWindowsCloseTheForm() {
        XCTAssertTrue(OverlayController.islandClickDismisses(windowLevel: .normal, isDictationPanel: false))
        XCTAssertFalse(OverlayController.islandClickDismisses(windowLevel: .normal, isDictationPanel: true))
        XCTAssertFalse(OverlayController.islandClickDismisses(windowLevel: .popUpMenu, isDictationPanel: false))
        XCTAssertFalse(OverlayController.islandClickDismisses(windowLevel: .floating, isDictationPanel: false))
        XCTAssertFalse(OverlayController.islandClickDismisses(windowLevel: nil, isDictationPanel: false))
    }
}
