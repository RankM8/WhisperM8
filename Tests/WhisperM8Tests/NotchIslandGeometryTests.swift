import SwiftUI
import XCTest
@testable import WhisperM8

/// Anzeige an einer Kamera-Insel (Dynamic Island): Erkennung nur aus den
/// öffentlichen `NSScreen`-Werten, in der Menüleiste nur ein Hals um die
/// Kamera, alles andere unter der Menüleiste. Die Werte des Insel-Bildschirms sind am 18.11.2026 auf einem
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

    /// In der Menüleiste liegt nur ein Hals um die Kamera: Aussparung plus
    /// 3 pt je Seite, von der Oberkante der Insel bis unter die Menüleiste.
    func testBandIsANeckAroundTheCamera() {
        let screen = islandScreen()
        let band = NotchIslandGeometry.band(screen: screen)
        XCTAssertEqual(NotchIslandGeometry.topInset(screen), 8, "Oberkante der Insel: ein Fünftel des Sicherheitsrands")
        XCTAssertEqual(band.width, 59 + 2 * NotchIslandGeometry.cutoutMargin, accuracy: 0.001)
        XCTAssertEqual(NotchIslandGeometry.cutoutMargin, 3)
        XCTAssertEqual(band.capsuleHeight, 32, "so hoch wie die Insel, ragt oben nicht über sie hinaus")
        XCTAssertEqual(band.neckHeight, 37, "bis unter die Menüleiste: 45 − 8")
        XCTAssertEqual(band.topRadius, 16)
    }

    /// Automatisch ausgeblendete Menüleiste: Das System meldet keine Höhe.
    /// Der Körper beginnt trotzdem dort, wo die Leiste beim Einfahren endet,
    /// sonst läge er dann 5 pt unter ihr.
    func testBodyStartsBelowAHiddenMenuBarToo() {
        let screen = islandScreen(menuBarHidden: true)
        XCTAssertEqual(screen.measuredMenuBarHeight, 0)
        XCTAssertEqual(NotchIslandGeometry.bodyTop(screen), 45)
        XCTAssertEqual(NotchIslandGeometry.band(screen: screen), NotchIslandGeometry.band(screen: islandScreen()))
        for mode in modes {
            XCTAssertEqual(
                NotchGeometry.layout(screen: screen, mode: mode).frame,
                NotchGeometry.layout(screen: islandScreen(), mode: mode).frame, "\(mode)")
        }
    }

    // MARK: Rahmen je Zustand

    private let modes: [NotchPanelMode] = [
        .compact(chipCount: 0), .compact(chipCount: 1), .compact(chipCount: 4), .alert,
        .expanded(rowCount: 1, sectionCount: 1), .expanded(rowCount: 6, sectionCount: 3),
    ]

    /// Wie an der Notch: In der Menüleiste nur die Aussparung (plus 3 pt
    /// Rand), alles andere hängt darunter. Menüs und Statussymbole neben der
    /// Kamera bleiben in jedem Zustand frei und klickbar.
    func testNothingVisibleTouchesTheMenuBarBesideTheCamera() {
        for screen in [islandScreen(), islandScreen(scale: 0.67), islandScreen(scale: 1.18), islandScreen(menuBarHidden: true)] {
            let areas = NotchGeometry.menuBarItemAreas(screen: screen)
            XCTAssertEqual(areas.count, 2)
            let menuBarBottom = screen.frame.maxY - NotchIslandGeometry.bodyTop(screen)
            for mode in modes {
                let layout = NotchGeometry.layout(screen: screen, mode: mode)
                XCTAssertEqual(layout.band.width, screen.notchWidth + 6, accuracy: 0.001, "\(mode)")
                XCTAssertEqual(layout.band.midX, screen.notchCenterX, accuracy: 0.001, "\(mode)")
                XCTAssertEqual(layout.band.maxY, screen.frame.maxY - screen.safeAreaTop / 5, accuracy: 0.001, "\(mode)")
                XCTAssertEqual(layout.band.minY, menuBarBottom, accuracy: 0.001, "\(mode)")
                // Der Körper hängt ganz unter der Menüleiste.
                XCTAssertEqual(layout.body.maxY, menuBarBottom, accuracy: 0.001, "\(mode)")
                XCTAssertEqual(layout.body.midX, screen.notchCenterX, accuracy: 0.001, "\(mode)")
                for area in areas {
                    XCTAssertLessThanOrEqual(layout.band.intersection(area).width, 3.001, "\(mode)")
                    XCTAssertTrue(layout.body.intersection(area).isEmpty, "\(mode)")
                }
                XCTAssertEqual(layout.frame, layout.band.union(layout.body))
                XCTAssertTrue(screen.frame.contains(layout.frame), "\(mode)")
            }
        }
    }

    /// Ruhe: Die Zeile mit den Zählern ist so breit, wie die Zähler brauchen
    /// (die Insel ist schmaler als sie), nie schmaler als der Hals.
    func testCompactRowFitsTheCounters() {
        let screen = islandScreen()
        let band = NotchIslandGeometry.band(screen: screen)
        XCTAssertEqual(NotchGeometry.layout(screen: screen, mode: .compact(chipCount: 0)).body.width, band.width)
        XCTAssertEqual(
            NotchGeometry.layout(screen: screen, mode: .compact(chipCount: 1)).body.width, band.width,
            "ein Zähler passt unter den Hals: gerade Kante statt kleiner Stufe")
        for chips in 2...4 {
            let body = NotchGeometry.layout(screen: screen, mode: .compact(chipCount: chips)).body
            XCTAssertEqual(body.width, 12 + CGFloat(chips) * 46, "\(chips)")
            XCTAssertEqual(body.height, NotchGeometry.chinHeight)
        }
        XCTAssertLessThan(NotchGeometry.layout(screen: screen, mode: .compact(chipCount: 4)).body.width, 200)
        XCTAssertEqual(NotchGeometry.layout(screen: screen, mode: .alert).body.width, NotchGeometry.alertWidth)
        XCTAssertEqual(
            NotchGeometry.layout(screen: screen, mode: .expanded(rowCount: 2, sectionCount: 1)).body.width,
            NotchGeometry.expandedMinWidth)
    }

    func testIslandLayoutScalesWithTheResolution() {
        let screen = islandScreen(scale: 1.18)
        let band = NotchIslandGeometry.band(screen: screen)
        XCTAssertEqual(band.width, 59 * 1.18 + 6, accuracy: 0.01)
        XCTAssertEqual(band.capsuleHeight, 32 * 1.18, accuracy: 0.01)
        let layout = NotchGeometry.layout(screen: screen, mode: .alert)
        XCTAssertEqual(layout.body.maxY, screen.frame.maxY - 45 * 1.18, accuracy: 0.01)
    }

    // MARK: Notch und Bildschirm ohne Aussparung bleiben, wie sie waren

    func testNotchLayoutIsUnchanged() {
        let screen = notchScreen()
        let compact = NotchGeometry.layout(screen: screen, mode: .compact(chipCount: 2))
        XCTAssertEqual(compact.band, CGRect(x: 663.5, y: 982 - 38, width: 185, height: 38))
        XCTAssertEqual(compact.body, CGRect(x: 663.5, y: 982 - 38 - 24, width: 185, height: 24))
        let alert = NotchGeometry.layout(screen: screen, mode: .alert)
        XCTAssertEqual(alert.band, compact.band)
        XCTAssertEqual(alert.body, CGRect(x: 756 - 170, y: 982 - 38 - 24, width: 340, height: 24))
        XCTAssertEqual(screen.fullscreenTopInsets, 38...38)
    }

    func testDisplayStylePerCutout() {
        XCTAssertEqual(NotchStatusController.displayStyle(screen: plainScreen), .pill)
        XCTAssertEqual(NotchStatusController.displayStyle(screen: notchScreen()), .notch(width: 185, height: 38))
        let island = NotchStatusController.displayStyle(screen: islandScreen())
        XCTAssertEqual(island, .island(NotchIslandGeometry.band(screen: islandScreen())))
        let display = NotchDisplay(style: island, summary: .empty, alert: nil, isExpanded: false, sections: [])
        XCTAssertTrue(display.isNotch)
        XCTAssertEqual(display.bandHeight, 37)
    }

    // MARK: Diktat und Controller-Insel

    func testDictationHangsFromTheCapsule() {
        let screen = islandScreen()
        let frame = UnifiedPillGeometry.notchDictationPanelFrame(screen: screen, panelWidth: 608)
        XCTAssertEqual(frame.maxY, screen.frame.maxY - 8, "Oberkante der Kapsel")
        XCTAssertEqual(frame.height, 37 + PillMetrics.height + UnifiedPillGeometry.shadowMargin)
        XCTAssertEqual(frame.midX, screen.notchCenterX, accuracy: 0.001)
        // Die Zeile selbst beginnt unter der Menüleiste.
        XCTAssertEqual(frame.maxY - 37, screen.frame.maxY - 45)
        XCTAssertEqual(OverlayPresentation.island(NotchIslandGeometry.band(screen: screen)).bandHeight, 37)
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
        XCTAssertEqual(frame.maxY, screen.frame.maxY - 8)
        XCTAssertEqual(frame.midX, screen.notchCenterX, accuracy: 0.001)
        XCTAssertEqual(ControllerIslandGeometry.panelFrame(screen: screen, bodySize: CGSize(width: 440, height: 200)), frame)
        // Notch unverändert: bündig an der Oberkante.
        XCTAssertEqual(
            ControllerIslandGeometry.frame(screen: notchScreen(), bodySize: CGSize(width: 440, height: 200)).maxY, 982)
    }

    // MARK: Vollbild

    /// Unter der Kamera-Insel beginnt ein Vollbild-Fenster unter der
    /// Menüleiste (45 pt) oder, mit ausgeblendeter Leiste, an der Unterkante
    /// der Kamera (40 pt). Beide Kanten zählen, in beiden Zuständen der Leiste.
    func testFullscreenBelowTheIslandAcceptsBothEdges() {
        for screen in [islandScreen(), islandScreen(menuBarHidden: true)] {
            XCTAssertEqual(screen.fullscreenTopInsets, 40...45)
            let quartz = NotchFullscreenDetector.quartzFrame(fromCocoa: screen.frame, primaryHeight: screen.frame.height)
            func detect(top: CGFloat, system: Bool = true) -> Bool {
                let window = NotchWindowSample(
                    layer: 0, bounds: CGRect(x: 0, y: top, width: 1736, height: 1133 - top), ownerPID: 7)
                return NotchFullscreenDetector.isFullscreen(
                    screenFrameQuartz: quartz, safeAreaTop: screen.fullscreenTopInsets.lowerBound,
                    maxTopInset: screen.fullscreenTopInsets.upperBound, windows: [window], ownPID: 1,
                    systemReportsFullScreen: system)
            }
            XCTAssertTrue(detect(top: 45), "unter der Menüleiste")
            XCTAssertTrue(detect(top: 40), "an der Unterkante der Kamera")
            XCTAssertTrue(detect(top: 0), "ganzer Bildschirm")
            XCTAssertFalse(detect(top: 45, system: false), "maximiertes Fenster ohne Vollbild-Meldung zählt nicht")
            XCTAssertFalse(detect(top: 60), "tiefer beginnt kein Vollbild")
            XCTAssertFalse(detect(top: 30), "höher als die Kamera auch nicht")
        }
    }

    /// An der Notch bleibt es bei genau einer Kante.
    func testFullscreenBelowTheNotchKeepsTheSingleEdge() {
        let screen = notchScreen()
        let quartz = NotchFullscreenDetector.quartzFrame(fromCocoa: screen.frame, primaryHeight: screen.frame.height)
        func detect(top: CGFloat) -> Bool {
            let window = NotchWindowSample(layer: 0, bounds: CGRect(x: 0, y: top, width: 1512, height: 982 - top), ownerPID: 7)
            return NotchFullscreenDetector.isFullscreen(
                screenFrameQuartz: quartz, safeAreaTop: screen.fullscreenTopInsets.lowerBound,
                maxTopInset: screen.fullscreenTopInsets.upperBound, windows: [window], ownPID: 1,
                systemReportsFullScreen: true)
        }
        XCTAssertTrue(detect(top: 38))
        XCTAssertFalse(detect(top: 43))
    }

    // MARK: Form

    private func shape(band: NotchIslandBand, bodyVisible: Bool) -> NotchHangingShape {
        NotchHangingShape(
            bandWidth: band.width, bandHeight: bodyVisible ? band.neckHeight : band.capsuleHeight,
            bottomRadius: 11, topRadius: band.topRadius)
    }

    /// Ohne Zeile darunter: eine Kapsel genau über der Kamera-Insel.
    func testBandAloneIsACapsule() {
        let band = NotchIslandGeometry.band(screen: islandScreen())
        let rect = CGRect(x: 0, y: 0, width: 200, height: band.capsuleHeight)
        let path = shape(band: band, bodyVisible: false).path(in: rect)
        let bounds = path.boundingRect
        XCTAssertEqual(bounds.width, band.width, accuracy: 0.01)
        XCTAssertEqual(bounds.height, band.capsuleHeight, accuracy: 0.01)
        XCTAssertEqual(bounds.midX, rect.midX, accuracy: 0.01)
        XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: rect.midY)), "über der Kamera")
        XCTAssertFalse(path.contains(CGPoint(x: bounds.minX + 1, y: 1)), "runde Ecke")
    }

    /// Mit Körper: Hals um die Kamera, darunter der breitere Körper; die
    /// Menüleiste neben dem Hals bleibt frei.
    func testNeckAndBodyLeaveTheMenuBarFree() {
        let band = NotchIslandGeometry.band(screen: islandScreen())
        let rect = CGRect(x: 0, y: 0, width: 340, height: band.neckHeight + NotchGeometry.chinHeight)
        let path = shape(band: band, bodyVisible: true).path(in: rect)
        XCTAssertEqual(path.boundingRect.width, 340, accuracy: 0.01)
        XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: 20)), "Hals")
        XCTAssertTrue(path.contains(CGPoint(x: 20, y: band.neckHeight + 12)), "Körper")
        XCTAssertFalse(path.contains(CGPoint(x: rect.midX - band.width / 2 - 4, y: 20)), "Menüleiste links vom Hals")
        XCTAssertFalse(path.contains(CGPoint(x: rect.midX + band.width / 2 + 4, y: 20)), "Menüleiste rechts vom Hals")
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
