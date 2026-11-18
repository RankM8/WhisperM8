import SwiftUI
import XCTest
@testable import WhisperM8

/// Anzeige an einer Kamera-Insel (Dynamic Island): Erkennung nur aus den
/// öffentlichen `NSScreen`-Werten, Kapsel um die Kamera, Körper unter der
/// Menüleiste. Die Werte des Insel-Bildschirms sind am 18.11.2026 auf einem
/// MacBook Pro mit Insel gemessen (macOS 27.2.1, Standard-Skalierung).
final class NotchIslandGeometryTests: XCTestCase {
    /// Gemessen: 1736 × 1133 pt, Menüleiste 45 pt, Sicherheitsrand 40 pt,
    /// freie Bereiche je 838,5 pt, also 59 pt Aussparung.
    private func islandScreen(scale: CGFloat = 1, menuBarHidden: Bool = false, id: UInt32 = 1) -> NotchScreenInfo {
        let width = 1736 * scale, height = 1133 * scale
        return NotchScreenInfo(
            displayID: id,
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            visibleFrame: CGRect(x: 0, y: 0, width: width, height: menuBarHidden ? height : height - 45 * scale),
            safeAreaTop: 40 * scale,
            auxiliaryLeftWidth: 838.5 * scale, auxiliaryRightWidth: 838.5 * scale,
            isBuiltIn: true)
    }

    /// 14-Zoll-MacBook-Pro mit Notch: ca. 185 pt breit, Menüleiste 38 pt.
    private func notchScreen(scale: CGFloat = 1) -> NotchScreenInfo {
        NotchScreenInfo(
            displayID: 2,
            frame: CGRect(x: 0, y: 0, width: 1512 * scale, height: 982 * scale),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512 * scale, height: 944 * scale),
            safeAreaTop: 38 * scale,
            auxiliaryLeftWidth: 663.5 * scale, auxiliaryRightWidth: 663.5 * scale,
            isBuiltIn: true)
    }

    private var plainScreen: NotchScreenInfo {
        NotchScreenInfo(
            displayID: 3,
            frame: CGRect(x: 1736, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 1736, y: 0, width: 2560, height: 1415),
            safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, isBuiltIn: false)
    }

    // MARK: Erkennung

    func testCutoutKindFromPublicScreenValues() {
        XCTAssertEqual(islandScreen().cutout, .island)
        XCTAssertEqual(notchScreen().cutout, .notch)
        XCTAssertEqual(plainScreen.cutout, .none)
        XCTAssertTrue(islandScreen().hasNotch, "beide Arten sind eine Aussparung")
        XCTAssertTrue(islandScreen().hasIsland)
        XCTAssertFalse(notchScreen().hasIsland)
    }

    /// Andere Auflösungen skalieren Breite und Tiefe gleich: Die Erkennung
    /// bleibt, ohne feste Maße.
    func testCutoutKindSurvivesScaledResolutions() {
        for scale in [0.67, 0.85, 1.0, 1.18, 1.5] as [CGFloat] {
            XCTAssertEqual(islandScreen(scale: scale).cutout, .island, "Insel bei \(scale)")
            XCTAssertEqual(notchScreen(scale: scale).cutout, .notch, "Notch bei \(scale)")
        }
    }

    /// Notch-Maße echter Geräte (Breite, Sicherheitsrand): nie eine Insel.
    func testKnownNotchSizesStayNotches() {
        for (width, depth) in [(185.0, 32.0), (185.0, 38.0), (174.0, 32.0), (208.0, 37.5), (200.0, 37.0)] {
            var screen = notchScreen()
            screen.safeAreaTop = depth
            let side = (screen.frame.width - width) / 2
            screen.auxiliaryLeftWidth = side
            screen.auxiliaryRightWidth = side
            XCTAssertEqual(screen.cutout, .notch, "\(width) × \(depth)")
        }
    }

    // MARK: Band

    func testBandSitsInTheMenuBarAroundTheCamera() {
        let screen = islandScreen()
        let band = NotchIslandGeometry.band(screen: screen)
        XCTAssertEqual(NotchIslandGeometry.topInset(screen), 5, "so viel Luft wie unter der Kamera: 45 − 40")
        XCTAssertEqual(band.cutoutWidth, 59, accuracy: 0.001)
        XCTAssertEqual(band.capsuleHeight, 35)
        XCTAssertEqual(band.neckHeight, 40, "bis unter die Menüleiste")
        XCTAssertEqual(band.width, 59 + 2 * NotchIslandGeometry.cutoutMargin)
        XCTAssertEqual(band.centerOffset, 0)
        XCTAssertEqual(band.topRadius, 17.5)
    }

    /// Automatisch ausgeblendete Menüleiste: Das System meldet keine Höhe.
    func testBandWithoutAMeasuredMenuBar() {
        let screen = islandScreen(menuBarHidden: true)
        let band = NotchIslandGeometry.band(screen: screen)
        XCTAssertEqual(NotchIslandGeometry.topInset(screen), 5, "ein Achtel des Sicherheitsrands")
        XCTAssertEqual(NotchIslandGeometry.bodyTop(screen), 40, "mindestens unter der Kamera")
        XCTAssertEqual(band.capsuleHeight, 35)
        XCTAssertEqual(band.neckHeight, 35)
    }

    func testChipsAreSplitAroundTheCamera() {
        XCTAssertTrue(NotchIslandGeometry.chipSplit(chipCount: 0) == (0, 0))
        XCTAssertTrue(NotchIslandGeometry.chipSplit(chipCount: 1) == (1, 0))
        XCTAssertTrue(NotchIslandGeometry.chipSplit(chipCount: 2) == (1, 1))
        XCTAssertTrue(NotchIslandGeometry.chipSplit(chipCount: 3) == (2, 1))
        XCTAssertTrue(NotchIslandGeometry.chipSplit(chipCount: 4) == (2, 2))
    }

    /// Ein Zähler: Das Band wächst nur nach links, rechts bleibt der Rand.
    func testSingleChipGrowsTheBandToOneSideOnly() {
        let band = NotchIslandGeometry.band(screen: islandScreen(), chipCount: 1)
        XCTAssertEqual(band.trailingSlot, NotchIslandGeometry.cutoutMargin)
        XCTAssertGreaterThan(band.leadingSlot, 40)
        XCTAssertLessThan(band.centerOffset, 0, "Mitte des Bands links der Kamera")
        XCTAssertEqual(band.centeredWidth, 59 + 2 * band.leadingSlot)
    }

    /// Rechts der Kamera blendet das System die Mikrofon-Anzeige ein: Die
    /// Zähler lassen dort Luft.
    func testChipsLeaveRoomNextToTheCamera() {
        XCTAssertGreaterThanOrEqual(NotchIslandGeometry.slotInnerGap, 10)
        XCTAssertEqual(
            NotchIslandGeometry.slotWidth(chips: 2),
            NotchIslandGeometry.slotInnerGap + 2 * NotchIslandGeometry.chipWidth
                + NotchIslandGeometry.chipSpacing + NotchIslandGeometry.slotOuterPadding)
    }

    // MARK: Rahmen je Zustand

    /// Ruhe: nur die Kapsel in der Menüleiste, sie schließt die Aussparung ein
    /// und reicht genau bis zu deren Unterkante.
    func testCompactIsACapsuleAroundTheCutout() {
        let screen = islandScreen()
        let layout = NotchGeometry.layout(screen: screen, mode: .compact(chipCount: 2), chipCount: 2)
        let top = screen.frame.maxY
        XCTAssertEqual(layout.band.maxY, top - 5)
        XCTAssertEqual(layout.band.minY, top - 40, "Unterkante der Kamera laut System")
        XCTAssertEqual(layout.body.height, 0)
        XCTAssertLessThanOrEqual(layout.band.minX, 838.5 - 40)
        XCTAssertGreaterThanOrEqual(layout.band.maxX, 897.5 + 40)
        XCTAssertEqual(layout.band.midX, screen.notchCenterX, accuracy: 0.001)
        XCTAssertEqual(layout.frame, layout.band, "zwei Zähler: links und rechts gleich")
        // Ganz in der Menüleiste, nichts hängt darunter.
        XCTAssertGreaterThanOrEqual(layout.frame.minY, top - 45)
    }

    /// Das Fenster steht in jedem Zustand um die Kamera zentriert: Die Zähler
    /// bleiben beim Wechsel der Zustände stehen.
    func testWindowStaysCenteredOnTheCamera() {
        let screen = islandScreen()
        for chips in 0...4 {
            for mode in [NotchPanelMode.compact(chipCount: chips), .alert, .expanded(rowCount: 4, sectionCount: 2)] {
                let layout = NotchGeometry.layout(screen: screen, mode: mode, chipCount: chips)
                XCTAssertEqual(layout.frame.midX, screen.notchCenterX, accuracy: 0.001, "\(chips) \(mode)")
                XCTAssertTrue(layout.frame.contains(layout.band), "\(chips) \(mode)")
                let compact = NotchGeometry.layout(screen: screen, mode: .compact(chipCount: chips), chipCount: chips)
                XCTAssertEqual(layout.band.minX, compact.band.minX, accuracy: 0.001, "Band steht: \(chips) \(mode)")
                XCTAssertEqual(layout.band.width, compact.band.width, accuracy: 0.001)
                XCTAssertEqual(layout.band.maxY, compact.band.maxY, accuracy: 0.001)
            }
        }
    }

    /// Hinweis und Liste hängen unter der Menüleiste; in der Leiste liegt nur
    /// das Band, nie breiter als in Ruhe.
    func testWideStatesHangBelowTheMenuBar() {
        let screen = islandScreen()
        let menuBarBottom = screen.frame.maxY - 45
        for mode in [NotchPanelMode.alert, .expanded(rowCount: 5, sectionCount: 3)] {
            let layout = NotchGeometry.layout(screen: screen, mode: mode, chipCount: 3)
            XCTAssertEqual(layout.body.maxY, menuBarBottom, "Körper beginnt unter der Menüleiste: \(mode)")
            XCTAssertEqual(layout.band.minY, menuBarBottom, "Hals reicht bis dorthin")
            XCTAssertEqual(layout.band.height, 40)
            XCTAssertEqual(layout.body.midX, screen.notchCenterX, accuracy: 0.001)
            for area in NotchGeometry.menuBarItemAreas(screen: screen) {
                XCTAssertFalse(layout.body.intersects(area), "Körper berührt die Menüleiste nicht: \(mode)")
            }
        }
        XCTAssertEqual(NotchGeometry.layout(screen: screen, mode: .alert, chipCount: 3).body.width, NotchGeometry.alertWidth)
        XCTAssertEqual(
            NotchGeometry.layout(screen: screen, mode: .expanded(rowCount: 2, sectionCount: 1), chipCount: 0).body.width,
            NotchGeometry.expandedMinWidth)
    }

    /// In der Menüleiste belegt die Anzeige höchstens das Band mit vier
    /// Zählern: unter 250 pt um die Kamera, egal in welchem Zustand.
    func testMenuBarCoverageIsBounded() {
        let screen = islandScreen()
        let widest = NotchIslandGeometry.band(screen: screen, chipCount: 4)
        XCTAssertLessThan(widest.width, 250)
        XCTAssertEqual(widest.leadingSlot, widest.trailingSlot)
    }

    func testIslandLayoutScalesWithTheResolution() {
        let screen = islandScreen(scale: 1.18)
        let band = NotchIslandGeometry.band(screen: screen, chipCount: 2)
        XCTAssertEqual(band.cutoutWidth, 59 * 1.18, accuracy: 0.01)
        XCTAssertEqual(band.capsuleHeight + NotchIslandGeometry.topInset(screen), 40 * 1.18, accuracy: 0.01)
        let layout = NotchGeometry.layout(screen: screen, mode: .alert, chipCount: 2)
        XCTAssertEqual(layout.body.maxY, screen.frame.maxY - 45 * 1.18, accuracy: 0.01)
    }

    // MARK: Notch und Bildschirm ohne Aussparung bleiben, wie sie waren

    func testNotchAndPlainScreensIgnoreTheChipCount() {
        for screen in [notchScreen(), plainScreen] {
            for mode in [NotchPanelMode.compact(chipCount: 3), .alert, .expanded(rowCount: 4, sectionCount: 2)] {
                XCTAssertEqual(
                    NotchGeometry.layout(screen: screen, mode: mode, chipCount: 3),
                    NotchGeometry.layout(screen: screen, mode: mode),
                    "\(screen.displayID) \(mode)")
            }
        }
    }

    func testNotchLayoutIsUnchanged() {
        let screen = notchScreen()
        let compact = NotchGeometry.layout(screen: screen, mode: .compact(chipCount: 2))
        XCTAssertEqual(compact.band, CGRect(x: 663.5, y: 982 - 38, width: 185, height: 38))
        XCTAssertEqual(compact.body, CGRect(x: 663.5, y: 982 - 38 - 24, width: 185, height: 24))
        let alert = NotchGeometry.layout(screen: screen, mode: .alert)
        XCTAssertEqual(alert.band, compact.band)
        XCTAssertEqual(alert.body, CGRect(x: 756 - 170, y: 982 - 38 - 24, width: 340, height: 24))
        XCTAssertEqual(screen.fullscreenTopInset, 38)
    }

    func testDisplayStylePerCutout() {
        let summary = NotchSummary(working: 2, waiting: 1)
        XCTAssertEqual(NotchStatusController.displayStyle(screen: plainScreen, summary: summary), .pill)
        XCTAssertEqual(
            NotchStatusController.displayStyle(screen: notchScreen(), summary: summary), .notch(width: 185, height: 38))
        XCTAssertEqual(
            NotchStatusController.displayStyle(screen: islandScreen(), summary: summary),
            .island(NotchIslandGeometry.band(screen: islandScreen(), chipCount: 2)))
    }

    // MARK: Diktat und Controller-Insel

    func testDictationHangsFromTheCapsule() {
        let screen = islandScreen()
        let frame = UnifiedPillGeometry.notchDictationPanelFrame(screen: screen, panelWidth: 608)
        XCTAssertEqual(frame.maxY, screen.frame.maxY - 5, "Oberkante der Kapsel")
        XCTAssertEqual(frame.height, 40 + PillMetrics.height + UnifiedPillGeometry.shadowMargin)
        XCTAssertEqual(frame.midX, screen.notchCenterX, accuracy: 0.001)
        // Die Zeile selbst beginnt unter der Menüleiste.
        XCTAssertEqual(frame.maxY - 40, screen.frame.maxY - 45)
        XCTAssertEqual(OverlayPresentation.island(NotchIslandGeometry.band(screen: screen)).bandHeight, 40)
        XCTAssertTrue(OverlayPresentation.island(NotchIslandGeometry.band(screen: screen)).isNotch)
    }

    func testDictationPlacementAtAnIslandIsTheNotchPlacement() {
        let placement = DictationPillPlacement.resolve(
            frontWindowDisplayID: 1, mouseDisplayID: nil, mainDisplayID: 1,
            screens: [islandScreen()], positions: [:])
        XCTAssertEqual(placement, .notch(islandScreen()))
    }

    func testControllerIslandHangsFromTheCapsule() {
        let screen = islandScreen()
        let style = ControllerIslandGeometry.style(for: screen)
        XCTAssertEqual(style, .island(NotchIslandGeometry.band(screen: screen)))
        let frame = ControllerIslandGeometry.frame(screen: screen, bodySize: CGSize(width: 440, height: 200))
        XCTAssertEqual(frame.maxY, screen.frame.maxY - 5)
        XCTAssertEqual(frame.midX, screen.notchCenterX, accuracy: 0.001)
        XCTAssertEqual(ControllerIslandGeometry.panelFrame(screen: screen, bodySize: CGSize(width: 440, height: 200)), frame)
        // Steht die Notch-Anzeige dort mit Zählern, deckt das Band ihre Kapsel.
        XCTAssertEqual(
            ControllerIslandGeometry.style(for: screen, chipCount: 3),
            .island(NotchIslandGeometry.band(screen: screen, chipCount: 3)))
        let wide = ControllerIslandDisplay(
            style: ControllerIslandGeometry.style(for: screen, chipCount: 4),
            model: ControllerIslandModel(
                target: ControllerIslandTarget(title: "Chat", status: .idle),
                content: .writing(ControllerWritingSlots(state: ControllerChatState(status: .idle, profile: .claude)))))
        XCTAssertGreaterThanOrEqual(wide.bodyWidth, NotchIslandGeometry.band(screen: screen, chipCount: 4).centeredWidth)
        // Notch unverändert: bündig an der Oberkante.
        XCTAssertEqual(
            ControllerIslandGeometry.frame(screen: notchScreen(), bodySize: CGSize(width: 440, height: 200)).maxY, 982)
    }

    func testRestLookAtAnIsland() {
        let band = NotchIslandGeometry.band(screen: islandScreen(), chipCount: 2)
        let summary = NotchSummary(working: 1, waiting: 1)
        let rest = UnifiedPillRestLook.island(summary: summary, alert: nil, band: band, bodyWidth: band.centeredWidth)
        XCTAssertTrue(rest.isNotch)
        XCTAssertEqual(rest.rowHeight, 0, "Ruhe: nur die Kapsel, keine Zeile darunter")
        let alert = NotchAlert(sessionID: UUID(), title: "Chat", kind: .awaitingInput)
        XCTAssertEqual(
            UnifiedPillRestLook.island(summary: summary, alert: alert, band: band, bodyWidth: 340).rowHeight,
            NotchGeometry.chinHeight)
    }

    // MARK: Vollbild

    /// Unter der Kamera-Insel beginnt ein Vollbild-Fenster unter der
    /// Menüleiste (45 pt), nicht an der Unterkante der Kamera (40 pt).
    func testFullscreenBelowTheIslandStartsUnderTheMenuBar() {
        let screen = islandScreen()
        XCTAssertEqual(screen.fullscreenTopInset, 45)
        let quartz = NotchFullscreenDetector.quartzFrame(fromCocoa: screen.frame, primaryHeight: screen.frame.height)
        let window = NotchWindowSample(layer: 0, bounds: CGRect(x: 0, y: 45, width: 1736, height: 1088), ownerPID: 7)
        XCTAssertTrue(NotchFullscreenDetector.isFullscreen(
            screenFrameQuartz: quartz, safeAreaTop: screen.fullscreenTopInset, windows: [window], ownPID: 1,
            systemReportsFullScreen: true))
        XCTAssertFalse(NotchFullscreenDetector.isFullscreen(
            screenFrameQuartz: quartz, safeAreaTop: screen.fullscreenTopInset, windows: [window], ownPID: 1,
            systemReportsFullScreen: false), "maximiertes Fenster ohne Vollbild-Meldung zählt nicht")
    }

    // MARK: Form

    private func shape(band: NotchIslandBand, bodyVisible: Bool) -> NotchHangingShape {
        NotchHangingShape(
            bandWidth: band.width, bandHeight: bodyVisible ? band.neckHeight : band.capsuleHeight,
            bottomRadius: 11, topRadius: band.topRadius, bandOffset: band.centerOffset)
    }

    /// Ruhe: eine Kapsel genau über dem Band, daneben ist das Fenster leer.
    func testCompactShapeIsACapsuleOverTheBand() {
        let band = NotchIslandGeometry.band(screen: islandScreen(), chipCount: 1)
        let rect = CGRect(x: 0, y: 0, width: band.centeredWidth, height: band.capsuleHeight)
        let path = shape(band: band, bodyVisible: false).path(in: rect)
        let bounds = path.boundingRect
        XCTAssertEqual(bounds.width, band.width, accuracy: 0.01)
        XCTAssertEqual(bounds.height, band.capsuleHeight, accuracy: 0.01)
        XCTAssertEqual(bounds.midX, rect.midX + band.centerOffset, accuracy: 0.01)
        XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: rect.midY)), "über der Kamera")
        XCTAssertFalse(path.contains(CGPoint(x: rect.maxX - 8, y: rect.midY)), "rechts, wo kein Zähler steht")
        XCTAssertFalse(path.contains(CGPoint(x: bounds.minX + 1, y: 1)), "runde Ecke")
    }

    /// Mit Körper: Hals um die Kamera, darunter der breitere Körper; die
    /// Menüleiste neben dem Hals bleibt frei.
    func testNeckAndBodyLeaveTheMenuBarFree() {
        let band = NotchIslandGeometry.band(screen: islandScreen(), chipCount: 2)
        let rect = CGRect(x: 0, y: 0, width: 340, height: band.neckHeight + NotchGeometry.chinHeight)
        let path = shape(band: band, bodyVisible: true).path(in: rect)
        XCTAssertEqual(path.boundingRect.width, 340, accuracy: 0.01)
        XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: 20)), "Hals")
        XCTAssertTrue(path.contains(CGPoint(x: 20, y: band.neckHeight + 12)), "Körper")
        XCTAssertFalse(path.contains(CGPoint(x: 20, y: 20)), "Menüleiste links vom Hals")
        XCTAssertFalse(path.contains(CGPoint(x: 320, y: 20)), "Menüleiste rechts vom Hals")
        XCTAssertFalse(path.contains(CGPoint(x: rect.midX - band.width / 2 + 1, y: 1)), "Hals oben rund")
    }

    /// Ohne `topRadius` zeichnet die Form die Notch wie bisher: eckiges Band
    /// bündig an der Oberkante.
    func testNotchShapeIsUnchanged() {
        let rect = CGRect(x: 0, y: 0, width: 340, height: 62)
        let path = NotchHangingShape(bandWidth: 185, bandHeight: 38, bottomRadius: 11).path(in: rect)
        XCTAssertTrue(path.contains(CGPoint(x: (340 - 185) / 2 + 0.5, y: 0.5)), "Band-Ecke oben eckig")
        XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: 50)))
        XCTAssertFalse(path.contains(CGPoint(x: 20, y: 20)))
    }
}
