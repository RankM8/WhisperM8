import SwiftUI
import XCTest
@testable import WhisperM8

/// Anzeige an einer Kamera-Insel (Dynamic Island): Erkennung nur aus den
/// öffentlichen `NSScreen`-Werten. In der Menüleiste wird die Kapsel um die
/// Kamera nur seitlich breiter und nur dort, wo die Messung Platz belegt;
/// Hinweis und Liste sind die große Form (`NotchIslandLargeGeometryTests`).
/// Die Werte des Insel-Bildschirms sind am 18.11.2026 auf einem MacBook Pro
/// mit Insel gemessen (macOS 27.2.1, Standard-Skalierung).
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

    /// Ohne Messung steht in Ruhe nur die Aussparung (plus 3 pt Rand) in der
    /// Menüleiste: Menüs und Statussymbole neben der Kamera bleiben frei und
    /// klickbar. Hinweis und Liste sind die große Form um die Kamera (sie
    /// darf Menüs verdecken, solange sie offen ist); das Band nennt dann die
    /// Kapsel, aus der sie wächst.
    func testRestTouchesNothingBesideTheCameraAndTheOpenFormIsOneShape() {
        for screen in [islandScreen(), islandScreen(scale: 0.67), islandScreen(scale: 1.18), islandScreen(menuBarHidden: true)] {
            let areas = NotchGeometry.menuBarItemAreas(screen: screen)
            XCTAssertEqual(areas.count, 2)
            for mode in modes {
                let layout = NotchGeometry.layout(screen: screen, mode: mode)
                XCTAssertEqual(layout.band.width, screen.notchWidth + 6, accuracy: 0.001, "\(mode)")
                XCTAssertEqual(layout.band.midX, screen.notchCenterX, accuracy: 0.001, "\(mode)")
                XCTAssertEqual(layout.band.maxY, screen.frame.maxY - screen.safeAreaTop / 5, accuracy: 0.001, "\(mode)")
                XCTAssertEqual(layout.band.minY, screen.frame.maxY - screen.safeAreaTop, accuracy: 0.001, "\(mode)")
                for area in areas {
                    XCTAssertLessThanOrEqual(layout.band.intersection(area).width, 3.001, "\(mode)")
                }
                if case .compact = mode {
                    // Ruhe: nur die Kapsel, nichts sonst.
                    XCTAssertTrue(layout.body.isEmpty, "\(mode)")
                    XCTAssertEqual(layout.frame, layout.band)
                } else {
                    // Eine Fläche, kein Hals: Der Rahmen ist die Form selbst.
                    XCTAssertEqual(layout.frame, layout.body, "\(mode)")
                    XCTAssertEqual(layout.frame.midX, screen.notchCenterX, accuracy: 0.001, "\(mode)")
                    XCTAssertEqual(layout.frame.maxY, NotchIslandLargeGeometry.windowTop(screen), accuracy: 0.001, "\(mode)")
                    XCTAssertTrue(layout.frame.contains(layout.band), "die Form wächst aus der Kapsel")
                }
                XCTAssertTrue(screen.frame.contains(layout.frame), "\(mode)")
            }
        }
    }

    // MARK: Kompakt, minimal, nichts

    /// Rahmen in der Menüleiste (Menü oder Statussymbol), in Punkten ab dem
    /// linken Bildschirmrand.
    private func barItem(_ screen: NotchScreenInfo, from minX: CGFloat, to maxX: CGFloat) -> CGRect {
        let height = NotchIslandGeometry.bodyTop(screen)
        return CGRect(x: screen.frame.minX + minX, y: screen.frame.maxY - height, width: maxX - minX, height: height)
    }

    /// Menüs bis 561 pt, Statussymbole ab 1151 pt: wie am 18.11.2026 gemessen.
    private func roomyBar(_ screen: NotchScreenInfo) -> NotchMenuBarOccupancy {
        NotchMenuBarOccupancy(frames: [barItem(screen, from: 10, to: 561), barItem(screen, from: 1151, to: 1716)])
    }

    private func signal(_ kind: NotchIslandSignal.Kind = .working, _ count: Int = 2) -> NotchIslandSignal {
        NotchIslandSignal(kind: kind, count: count)
    }

    /// Ein Zeichen, eine Zahl: wartet ein Chat, zählt das zuerst; dann
    /// Fehler, Arbeit, frisch fertig. Nichts los: kein Zeichen.
    func testSignalIsTheMostImportantState() {
        XCTAssertNil(NotchIslandSignal(summary: .empty))
        XCTAssertEqual(
            NotchIslandSignal(summary: NotchSummary(working: 3, waiting: 2, errored: 1, freshDone: 4)), signal(.waiting, 2))
        XCTAssertEqual(NotchIslandSignal(summary: NotchSummary(working: 3, errored: 1, freshDone: 4)), signal(.errored, 1))
        XCTAssertEqual(NotchIslandSignal(summary: NotchSummary(working: 3, freshDone: 4)), signal(.working, 3))
        XCTAssertEqual(NotchIslandSignal(summary: NotchSummary(freshDone: 4)), signal(.done, 4))
        XCTAssertEqual(signal(.working, 7).digits, 1)
        XCTAssertEqual(signal(.working, 12).digits, 2)
        XCTAssertEqual(signal(.working, 250).text, "99", "höchstens zwei Ziffern")
    }

    /// Kompakt wird die Insel nur seitlich breiter, und nur auf einer Seite:
    /// Zeichen und Zahl stehen zusammen links der Kamera. Gleiche Höhe,
    /// gleiche Oberkante, nichts unter der Menüleiste.
    func testCompactWidensOnlySideways() {
        let screen = islandScreen()
        let occupancy = roomyBar(screen)
        XCTAssertEqual(
            NotchIslandGeometry.presentation(signal: signal(), screen: screen, occupancy: occupancy), .compact(.leading))
        let band = NotchIslandGeometry.band(screen: screen, occupancy: occupancy, presentation: .compact(.leading))
        XCTAssertEqual(band.leadingWing, 40, "Rand um die Kamera plus Zeichen und Zahl")
        XCTAssertEqual(band.trailingWing, NotchIslandGeometry.cutoutMargin, "rechts nur der Rand")
        XCTAssertEqual(band.width, 59 + 40 + 3, accuracy: 0.001)
        XCTAssertTrue(band.hasLeadingContent && band.showsValue)
        XCTAssertFalse(band.hasTrailingContent)
        let layout = NotchGeometry.layout(screen: screen, mode: .compact(chipCount: 1), islandBand: band)
        XCTAssertEqual(layout.frame.height, 32)
        XCTAssertEqual(layout.frame.maxY, screen.frame.maxY - 8)
        XCTAssertEqual(layout.frame.maxX, screen.notchCenterX + 59 / 2 + 3, accuracy: 0.001, "wächst nur nach links")
        XCTAssertGreaterThanOrEqual(layout.frame.minY, screen.frame.maxY - 45, "nichts unter der Menüleiste")
        // Zwei Ziffern brauchen etwas mehr.
        let wide = NotchIslandGeometry.band(screen: screen, occupancy: occupancy, presentation: .compact(.leading), digits: 2)
        XCTAssertEqual(wide.leadingWing, 48)
        // Rechts der Kamera: gespiegelt.
        let right = NotchIslandGeometry.band(screen: screen, occupancy: occupancy, presentation: .compact(.trailing))
        XCTAssertEqual(right.trailingWing, 40)
        XCTAssertEqual(right.leadingWing, NotchIslandGeometry.cutoutMargin)
        XCTAssertTrue(right.hasTrailingContent && right.showsValue)
    }

    /// Ohne Messung (keine Berechtigung) und ohne Zeichen steht nichts in der
    /// Menüleiste. Zeichen und Zahl stehen links der Kamera; reichen die
    /// Menüs heran, rechts. Passt beides nirgends, bleibt nur das Zeichen auf
    /// der Seite mit Platz; ist keine frei, nichts.
    func testPresentationNeedsMeasuredRoom() {
        let screen = islandScreen()
        func stage(_ frames: [CGRect], _ signal: NotchIslandSignal? = NotchIslandSignal(kind: .working, count: 2)) -> NotchIslandPresentation {
            NotchIslandGeometry.presentation(signal: signal, screen: screen, occupancy: NotchMenuBarOccupancy(frames: frames))
        }
        XCTAssertEqual(NotchIslandGeometry.presentation(signal: signal(), screen: screen, occupancy: nil), .hidden)
        XCTAssertEqual(stage([], nil), .hidden, "nichts los: nichts von uns")
        XCTAssertEqual(stage([]), .compact(.leading))
        // Aussparung 838,5 bis 897,5; kompakt braucht auf einer Seite 3 + 37 + 6 pt.
        XCTAssertEqual(stage([barItem(screen, from: 10, to: 792)]), .compact(.leading))
        XCTAssertEqual(stage([barItem(screen, from: 10, to: 794)]), .compact(.trailing), "Menüs reichen heran: beides rechts")
        XCTAssertEqual(stage([barItem(screen, from: 928, to: 1716)]), .compact(.leading), "rechts belegt stört links nicht")
        // Für die Zahl reicht es auf keiner Seite: nur das Zeichen (3 + 23 + 6 pt).
        XCTAssertEqual(stage([barItem(screen, from: 10, to: 800), barItem(screen, from: 940, to: 1716)]), .minimal(.leading))
        XCTAssertEqual(stage([barItem(screen, from: 10, to: 820), barItem(screen, from: 935, to: 1716)]), .minimal(.trailing))
        XCTAssertEqual(stage([barItem(screen, from: 10, to: 820), barItem(screen, from: 920, to: 1716)]), .hidden)
        // Zwei Ziffern passen links nicht mehr, rechts schon.
        let tight = [barItem(screen, from: 10, to: 790), barItem(screen, from: 1151, to: 1716)]
        XCTAssertEqual(stage(tight, signal(.working, 2)), .compact(.leading))
        XCTAssertEqual(stage(tight, signal(.working, 12)), .compact(.trailing))
        // Menüs, die rechts der Kamera weiterlaufen, zählen genauso.
        XCTAssertEqual(stage([barItem(screen, from: 10, to: 838), barItem(screen, from: 898, to: 960)]), .hidden)
        // Notch und Bildschirm ohne Aussparung kennen die Stufen nicht.
        XCTAssertEqual(NotchIslandGeometry.presentation(signal: signal(), screen: notchScreen(), occupancy: roomyBar(notchScreen())), .hidden)
    }

    /// Das eine Muss: Kompakt und minimal schneiden nie einen gemessenen
    /// Rahmen, wo auch immer Menüs und Statussymbole enden, auch nicht mit
    /// Hinweis oder Liste darunter.
    func testCompactAndMinimalNeverCutMeasuredMenuFrames() {
        for screen in [islandScreen(), islandScreen(scale: 0.67), islandScreen(scale: 1.18)] {
            let cutoutMinX = screen.notchCenterX - screen.notchWidth / 2
            let cutoutMaxX = screen.notchCenterX + screen.notchWidth / 2
            for leftGap in stride(from: CGFloat(0), through: 80, by: 3.5) {
                for rightGap in stride(from: CGFloat(0), through: 80, by: 3.5) {
                    let frames = [
                        barItem(screen, from: 10, to: cutoutMinX - leftGap),
                        barItem(screen, from: cutoutMaxX + rightGap, to: screen.frame.width - 20),
                    ]
                    for count in [1, 12, -1] {
                        // -1: Apples Insel zeigt selbst etwas, unser Zeichen steht abgesetzt daneben.
                        var occupancy = NotchMenuBarOccupancy(frames: frames)
                        if count < 0 { occupancy.systemIsland = (cutoutMinX - 20)...(cutoutMaxX + 30) }
                        let signal = signal(.waiting, abs(count))
                        let stage = NotchIslandGeometry.presentation(signal: signal, screen: screen, occupancy: occupancy)
                        let band = NotchIslandGeometry.band(
                            screen: screen, occupancy: occupancy, presentation: stage, digits: signal.digits)
                        for mode in modes {
                            let layout = NotchGeometry.layout(screen: screen, mode: mode, islandBand: band)
                            // Flügel mit Zeichen bzw. Zahl: ganz frei.
                            let leading = CGRect(
                                x: layout.band.minX, y: layout.band.minY, width: band.leadingContent, height: layout.band.height)
                            let trailing = CGRect(
                                x: layout.band.maxX - band.trailingContent, y: layout.band.minY,
                                width: band.trailingContent, height: layout.band.height)
                            for frame in frames {
                                // Um die Kamera höchstens der schmale Rand, wie bisher.
                                let cut = layout.band.intersection(frame)
                                XCTAssertLessThanOrEqual(cut.isNull ? 0 : cut.width, 3.001, "\(stage) \(leftGap) \(rightGap) \(mode)")
                                if let detached = band.detachedFrame { XCTAssertFalse(detached.intersects(frame), "\(leftGap) \(rightGap)") }
                                XCTAssertFalse(band.hasLeadingContent && leading.intersects(frame), "\(stage) \(leftGap) \(rightGap)")
                                XCTAssertFalse(band.hasTrailingContent && trailing.intersects(frame), "\(stage) \(leftGap) \(rightGap)")
                                // Nur die offene große Form darf Menüs verdecken.
                                if case .compact = mode { XCTAssertTrue(layout.body.isEmpty, "\(mode)") }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Zeigt Apples Insel selbst etwas (Kamera-Hinweis, gemessen 802 bis
    /// 945 pt, 6 bis 40 pt unter der Kante), liegt ihr Fenster über unserem.
    /// Unser Zeichen steht dann als eigener Kreis mit Abstand neben ihr (wie
    /// bei zwei Live Activities), und der Hals ist so breit wie sie.
    func testSystemIslandDetachesTheSign() {
        let screen = islandScreen()
        var occupancy = roomyBar(screen)
        occupancy.systemIsland = 802...945
        occupancy.systemIslandInsets = 6...40
        XCTAssertEqual(NotchIslandGeometry.presentation(signal: signal(), screen: screen, occupancy: occupancy), .minimal(.leading))
        let band = NotchIslandGeometry.band(screen: screen, occupancy: occupancy, presentation: .minimal(.leading))
        let layout = NotchGeometry.layout(screen: screen, mode: .compact(chipCount: 1), islandBand: band)
        XCTAssertEqual(layout.frame.size, CGSize(width: 34, height: 34), "ein Kreis, so hoch wie Apples Insel")
        XCTAssertEqual(layout.frame.maxX, 802 - 2 - 6, accuracy: 0.001, "mit Abstand links neben ihr")
        XCTAssertEqual(layout.frame.maxY, screen.frame.maxY - 6)
        XCTAssertFalse(band.hasLeadingContent || band.hasTrailingContent)

        // Schnellaktion, Aufnahme per Controller, Controller-Insel: der
        // Hals, so breit wie Apples Insel.
        let neck = NotchIslandGeometry.band(screen: screen, occupancy: occupancy)
        XCTAssertEqual(neck.width, 945 - 802 + 2 * NotchIslandGeometry.systemRim, accuracy: 0.001)
        XCTAssertNil(neck.detachedFrame)
        // Hinweis und Liste wachsen aus dem Kreis.
        let alert = NotchGeometry.layout(screen: screen, mode: .alert, islandBand: band)
        XCTAssertEqual(alert.band, layout.frame)
        XCTAssertEqual(NotchIslandGeometry.band(screen: screen, occupancy: roomyBar(screen)), NotchIslandGeometry.band(screen: screen))

        // Links kein Platz: Kreis rechts neben ihr. Nirgends Platz: nichts,
        // und der Hals reicht nur bis zum nächsten Menü.
        occupancy.frames = [barItem(screen, from: 10, to: 770), barItem(screen, from: 1151, to: 1716)]
        XCTAssertEqual(NotchIslandGeometry.presentation(signal: signal(), screen: screen, occupancy: occupancy), .minimal(.trailing))
        let right = NotchIslandGeometry.band(screen: screen, occupancy: occupancy, presentation: .minimal(.trailing))
        XCTAssertEqual(right.detachedFrame?.minX ?? 0, 945 + 2 + 6, accuracy: 0.001)
        occupancy.frames = [barItem(screen, from: 10, to: 820), barItem(screen, from: 960, to: 1716)]
        XCTAssertEqual(NotchIslandGeometry.presentation(signal: signal(), screen: screen, occupancy: occupancy), .hidden)
        let squeezed = NotchIslandGeometry.band(screen: screen, occupancy: occupancy)
        XCTAssertGreaterThanOrEqual(screen.notchCenterX - screen.notchWidth / 2 - squeezed.leadingWing, 820)
        XCTAssertLessThanOrEqual(screen.notchCenterX + screen.notchWidth / 2 + squeezed.trailingWing, 960)
    }

    // MARK: Diktat-Kapsel

    /// Das Diktat steht als eigene Kapsel in der Menüleiste links neben der
    /// Insel, mit Platz für Apples Mikrofon-Hinweis (links 36,5 pt) und 6 pt
    /// Abstand; gleiche Höhe und Oberkante wie die Insel, nichts darunter.
    func testDictationCapsuleSitsBesideTheIsland() throws {
        let screen = islandScreen()
        let capsule = try XCTUnwrap(NotchIslandGeometry.dictationCapsule(screen: screen, occupancy: roomyBar(screen)))
        XCTAssertEqual(capsule.side, .leading)
        XCTAssertTrue(capsule.showsClock)
        let frame = capsule.frame(screen: screen)
        XCTAssertEqual(frame.width, NotchIslandGeometry.dictationCompactWidth)
        XCTAssertEqual(frame.maxX, 838.5 - 36.5 - 6, accuracy: 0.001)
        XCTAssertEqual(frame.height, 32)
        XCTAssertEqual(frame.maxY, screen.frame.maxY - 8)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.frame.maxY - 45, "nichts unter der Menüleiste")
        // Mit Raute für wartende Chats etwas breiter, die Kante zur Insel bleibt.
        let badged = try XCTUnwrap(NotchIslandGeometry.dictationCapsule(screen: screen, occupancy: roomyBar(screen), hasBadge: true))
        XCTAssertEqual(badged.frame(screen: screen).maxX, frame.maxX, accuracy: 0.001)
        XCTAssertEqual(badged.width, capsule.width + NotchIslandGeometry.dictationBadgeWidth)
        // Notch und Bildschirm ohne Aussparung: keine Kapsel, alles wie bisher.
        XCTAssertNil(NotchIslandGeometry.dictationCapsule(screen: notchScreen(), occupancy: roomyBar(notchScreen())))
        XCTAssertNil(NotchIslandGeometry.dictationCapsule(screen: plainScreen, occupancy: nil))
    }

    /// Stufen beim Diktat: mit Zeit links, sonst rechts, sonst nur die
    /// Wellenform. Ein Diktat steht immer in der Menüleiste: Ohne Platz oder
    /// ohne Messung die schmalste Form trotzdem, notfalls über einem Menütitel.
    func testDictationCapsuleStagesFollowTheRoom() throws {
        let screen = islandScreen()
        func capsule(_ frames: [CGRect]) -> NotchIslandDictationCapsule? {
            NotchIslandGeometry.dictationCapsule(screen: screen, occupancy: NotchMenuBarOccupancy(frames: frames))
        }
        // Links braucht die volle Kapsel 36,5 + 6 + 96 + 6 = 144,5 pt.
        XCTAssertEqual(capsule([barItem(screen, from: 10, to: 690)])?.side, .leading)
        let right = try XCTUnwrap(capsule([barItem(screen, from: 10, to: 700)]))
        XCTAssertEqual(right.side, .trailing)
        XCTAssertTrue(right.showsClock)
        XCTAssertEqual(right.frame(screen: screen).minX, 897.5 + 47.5 + 6, accuracy: 0.001)
        // Für die Zeit reicht es nirgends: nur die Wellenform (links 96,5 pt).
        let minimal = try XCTUnwrap(capsule([barItem(screen, from: 10, to: 740), barItem(screen, from: 1000, to: 1716)]))
        XCTAssertEqual(minimal.side, .leading)
        XCTAssertFalse(minimal.showsClock)
        XCTAssertEqual(minimal.width, NotchIslandGeometry.dictationMinimalWidth)
        XCTAssertFalse(minimal.isForced)
        // Nirgends Platz: die schmalste Form trotzdem, auf der Seite mit mehr Platz.
        let forced = try XCTUnwrap(capsule([barItem(screen, from: 10, to: 800), barItem(screen, from: 960, to: 1716)]))
        XCTAssertTrue(forced.isForced)
        XCTAssertFalse(forced.showsClock)
        XCTAssertEqual(forced.width, NotchIslandGeometry.dictationMinimalWidth)
        XCTAssertEqual(forced.side, .trailing, "rechts bleiben 15 pt neben Apples Insel, links 2")
        XCTAssertEqual(capsule([barItem(screen, from: 10, to: 780), barItem(screen, from: 946, to: 1716)])?.side, .leading)
        // Ohne Messung: höchstens die Mindestbreite, links.
        let blind = try XCTUnwrap(NotchIslandGeometry.dictationCapsule(screen: screen, occupancy: nil, hasBadge: false))
        XCTAssertEqual(blind.width, NotchIslandGeometry.dictationMinimalWidth)
        XCTAssertFalse(blind.showsClock)
        XCTAssertEqual(blind.side, .leading)
        XCTAssertTrue(blind.isForced)
    }

    /// Die Diktat-Kapsel schneidet bei keiner Lage von Menüs und
    /// Statussymbolen einen gemessenen Rahmen, solange auf einer Seite Platz
    /// ist; nur wenn nirgends Platz ist, steht sie trotzdem da (`isForced`).
    /// Über der Kamera liegt sie nie.
    func testDictationCapsuleNeverCutsMeasuredMenuFrames() {
        for screen in [islandScreen(), islandScreen(scale: 0.67), islandScreen(scale: 1.18)] {
            let cutoutMinX = screen.notchCenterX - screen.notchWidth / 2
            let cutoutMaxX = screen.notchCenterX + screen.notchWidth / 2
            for leftGap in stride(from: CGFloat(0), through: 180, by: 7.5) {
                for rightGap in stride(from: CGFloat(0), through: 180, by: 7.5) {
                    let frames = [
                        barItem(screen, from: 10, to: cutoutMinX - leftGap),
                        barItem(screen, from: cutoutMaxX + rightGap, to: screen.frame.width - 20),
                    ]
                    for system in [nil, (cutoutMinX - 36.5)...(cutoutMaxX + 47.5)] as [ClosedRange<CGFloat>?] {
                        for badge in [false, true] {
                            let occupancy = NotchMenuBarOccupancy(frames: frames, systemIsland: system)
                            guard let capsule = NotchIslandGeometry.dictationCapsule(
                                screen: screen, occupancy: occupancy, hasBadge: badge) else {
                                XCTFail("an der Insel gibt es immer eine Kapsel")
                                continue
                            }
                            let frame = capsule.frame(screen: screen)
                            if capsule.isForced {
                                // Erzwungen nur, wenn die schmalste Form auf keiner Seite Platz hat.
                                XCTAssertFalse(capsule.showsClock)
                                let reserve = NotchIslandGeometry.dictationReserve(screen: screen, occupancy: occupancy)
                                let width = capsule.width + NotchIslandGeometry.detachedGap + NotchIslandGeometry.menuClearance
                                XCTAssertLessThan(leftGap, reserve.leading + width, "\(leftGap) \(rightGap)")
                                XCTAssertLessThan(rightGap, reserve.trailing + width, "\(leftGap) \(rightGap)")
                            } else {
                                for item in frames { XCTAssertFalse(frame.intersects(item), "\(leftGap) \(rightGap) \(capsule)") }
                            }
                            XCTAssertTrue(frame.maxX <= cutoutMinX || frame.minX >= cutoutMaxX, "nie über der Kamera")
                        }
                    }
                }
            }
        }
    }

    /// Apples Mikrofon-Hinweis (bis 143 pt, 802 bis 945) hat von Anfang an
    /// Platz. Zeigt die Messung eine breitere Insel, rückt die Kapsel nach
    /// außen und bleibt dort, auch wenn die Insel wieder schrumpft.
    func testDictationCapsuleMovesOutwardOnly() {
        let screen = islandScreen()
        var occupancy = roomyBar(screen)
        let start = NotchIslandGeometry.dictationReserve(screen: screen, occupancy: occupancy)
        XCTAssertEqual(start.leading, 36.5)
        XCTAssertEqual(start.trailing, 47.5)
        for system in [812...923.5, 802...945] as [ClosedRange<CGFloat>] {
            occupancy.systemIsland = system
            let reserve = NotchIslandGeometry.dictationReserve(screen: screen, occupancy: occupancy, previous: start)
            XCTAssertEqual(reserve.leading, 36.5, "der Hinweis passt in den freigehaltenen Platz")
            XCTAssertEqual(reserve.trailing, 47.5)
        }
        occupancy.systemIsland = 760...960
        let wide = NotchIslandGeometry.dictationReserve(screen: screen, occupancy: occupancy, previous: start)
        XCTAssertEqual(wide.leading, 78.5)
        XCTAssertEqual(wide.trailing, 62.5)
        occupancy.systemIsland = 812...923.5
        let after = NotchIslandGeometry.dictationReserve(screen: screen, occupancy: occupancy, previous: wide)
        XCTAssertEqual(after.leading, 78.5, "bleibt außen")
        XCTAssertEqual(after.trailing, 62.5)
        // Die Kapsel liegt nie unter Apples Insel, wie breit die auch ist.
        let capsule = NotchIslandGeometry.dictationCapsule(screen: screen, occupancy: occupancy, reserve: wide)
        XCTAssertLessThanOrEqual(capsule?.frame(screen: screen).maxX ?? .infinity, 760 - 6)
    }

    /// Hinweis und Liste: eine Fläche um die Kamera, kein Hals mit Kasten.
    /// Das Band nennt die Kapsel in Ruhe (sie sitzt mit einem Flügel neben
    /// der Mitte); die Form selbst bleibt auf die Kamera zentriert.
    func testAlertAndListAreOneFormAroundTheCamera() {
        let screen = islandScreen()
        let band = NotchIslandGeometry.band(screen: screen, occupancy: roomyBar(screen), presentation: .compact(.leading))
        let rest = NotchGeometry.layout(screen: screen, mode: .compact(chipCount: 1), islandBand: band)
        let alert = NotchGeometry.layout(screen: screen, mode: .alert, islandBand: band)
        XCTAssertEqual(alert.band, rest.frame)
        XCTAssertEqual(alert.frame, CGRect(x: 868 - 190, y: 1133 - 6 - 108, width: 380, height: 108))
        let list = NotchGeometry.layout(screen: screen, mode: .expanded(rowCount: 2, sectionCount: 1), islandBand: band)
        XCTAssertEqual(list.frame.width, 420)
        XCTAssertEqual(list.frame.midX, screen.notchCenterX, accuracy: 0.001)
        XCTAssertEqual(list.frame.maxY, alert.frame.maxY, "gleiche Oberkante")
        // Ein einzelner Flügel: Die Kapsel sitzt neben der Mitte, die Form nicht.
        let minimal = NotchIslandGeometry.band(screen: screen, occupancy: roomyBar(screen), presentation: .minimal(.leading))
        XCTAssertEqual(minimal.centerOffset, -11.5, accuracy: 0.001)
        let hanging = NotchGeometry.layout(screen: screen, mode: .alert, islandBand: minimal)
        XCTAssertEqual(hanging.band.midX, screen.notchCenterX - 11.5, accuracy: 0.001)
        XCTAssertEqual(hanging.frame.midX, screen.notchCenterX, accuracy: 0.001)
    }

    func testIslandLayoutScalesWithTheResolution() {
        let screen = islandScreen(scale: 1.18)
        let band = NotchIslandGeometry.band(screen: screen)
        XCTAssertEqual(band.width, 59 * 1.18 + 6, accuracy: 0.01)
        XCTAssertEqual(band.capsuleHeight, 32 * 1.18, accuracy: 0.01)
        XCTAssertEqual(band.neckHeight, 37 * 1.18, accuracy: 0.01)
        XCTAssertEqual(band.topGap, 2 * 1.18, accuracy: 0.01)
        let layout = NotchGeometry.layout(screen: screen, mode: .alert)
        XCTAssertEqual(layout.frame.maxY, screen.frame.maxY - 6 * 1.18, accuracy: 0.01)
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
        XCTAssertEqual(display.bandHeight, 32, "Ruhe: nur die Kapsel")
        // Hinweis und Liste zeichnet die große Form, nicht mehr ein Hals.
        XCTAssertNil(display.islandLarge)
    }

    // MARK: Diktat und Controller-Insel

    /// Das Fenster des Diktats beginnt auf Höhe der großen Form (6 pt), die
    /// Kapsel 2 pt darunter. Die Zeile von Schnellaktion und Aufnahme per
    /// Controller beginnt weiter unter der Menüleiste.
    func testDictationHangsFromTheCapsule() {
        let screen = islandScreen()
        let frame = UnifiedPillGeometry.notchDictationPanelFrame(screen: screen, panelWidth: 608)
        XCTAssertEqual(frame.maxY, screen.frame.maxY - 6, "Oberkante der großen Form")
        XCTAssertEqual(frame.midX, screen.notchCenterX, accuracy: 0.001)
        let presentation = OverlayPresentation.island(NotchIslandGeometry.band(screen: screen))
        XCTAssertEqual(presentation.islandTopGap, 2)
        XCTAssertEqual(presentation.bandHeight, 37)
        XCTAssertEqual(frame.maxY - presentation.islandTopGap - presentation.bandHeight, screen.frame.maxY - 45)
        XCTAssertGreaterThanOrEqual(frame.height, 2 + 37 + PillMetrics.height + UnifiedPillGeometry.shadowMargin)
        XCTAssertTrue(presentation.isNotch)
        XCTAssertEqual(OverlayPresentation.notch(width: 185, height: 38).islandTopGap, 0)
        XCTAssertEqual(OverlayPresentation.pill.islandTopGap, 0)
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

    /// Ein einzelner Flügel: Das Band sitzt neben der Mitte des Rahmens.
    func testBandCanSitBesideTheCentre() {
        let rect = CGRect(x: 0, y: 0, width: 340, height: 37 + NotchGeometry.chinHeight)
        let path = NotchHangingShape(
            bandWidth: 88, bandHeight: 37, bottomRadius: 11, topRadius: 16, bandOffset: -11.5).path(in: rect)
        XCTAssertTrue(path.contains(CGPoint(x: 170 - 11.5 - 40, y: 20)), "linker Flügel")
        XCTAssertFalse(path.contains(CGPoint(x: 170 - 11.5 + 48, y: 20)), "rechts endet das Band am Rand um die Kamera")
        XCTAssertTrue(path.contains(CGPoint(x: 20, y: 37 + 12)), "Körper")
        // Allein: eine Kapsel an derselben Stelle.
        let alone = NotchHangingShape(
            bandWidth: 88, bandHeight: 32, bottomRadius: 11, topRadius: 16, bandOffset: -11.5)
            .path(in: CGRect(x: 0, y: 0, width: 340, height: 32)).boundingRect
        XCTAssertEqual(alone.midX, 170 - 11.5, accuracy: 0.01)
        XCTAssertEqual(alone.width, 88, accuracy: 0.01)
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
