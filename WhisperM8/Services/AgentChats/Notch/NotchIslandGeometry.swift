import CoreGraphics
import Foundation

/// Art der Aussparung oben im Bildschirm. Abgeleitet nur aus dem, was
/// `NSScreen` öffentlich meldet (`safeAreaInsets`, `auxiliaryTop…Area`,
/// `visibleFrame`): kein Modellname, keine festen Maße je Gerät.
enum NotchCutoutKind: Equatable {
    case none
    /// Klassische Notch: breit, bündig an der Oberkante, so hoch wie die Menüleiste.
    case notch
    /// Kamera-Insel (Dynamic Island): schmale Kapsel, die in der Menüleiste schwebt.
    case island
}

/// Band der Anzeige an einer Kamera-Insel, in Punkten: ein schmaler Hals um
/// die Kamera. In der Menüleiste liegt nie mehr als das; Zähler, Hinweis,
/// Liste und Diktat hängen darunter.
struct NotchIslandBand: Equatable {
    /// Breite des Bands: die Aussparung plus ein schmaler Rand je Seite.
    var width: CGFloat
    /// Höhe der Kapsel um die Kamera (das Band, solange nichts darunter hängt).
    var capsuleHeight: CGFloat
    /// Höhe des Bands von der Oberkante der Kapsel bis zum Körper unter der Menüleiste.
    var neckHeight: CGFloat

    var topRadius: CGFloat { capsuleHeight / 2 }
}

extension NotchScreenInfo {
    /// Höhe der Menüleiste, wie sie das System gerade meldet (0, wenn sie
    /// automatisch ausgeblendet ist).
    var measuredMenuBarHeight: CGFloat { max(0, frame.maxY - visibleFrame.maxY) }

    /// Notch oder Kamera-Insel? Eine Insel ist viel schmaler als eine Notch:
    /// weniger als dreimal so breit, wie die Aussparung tief reicht. Das
    /// Verhältnis bleibt bei jeder Skalierung gleich (eine Notch liegt bei
    /// rund 5 bis 6, die Insel bei 1,5).
    var cutout: NotchCutoutKind {
        guard hasNotch else { return .none }
        return notchWidth < NotchIslandGeometry.maxIslandAspect * safeAreaTop ? .island : .notch
    }

    var hasIsland: Bool { cutout == .island }

    /// Wo ein Vollbild-Fenster unter der Kamera beginnen kann (Abstand zur
    /// Oberkante): an der Notch an ihrer Unterkante. An der Insel irgendwo
    /// zwischen Unterkante der Kamera und Unterkante der Menüleiste, je
    /// nachdem, ob die Leiste eingeblendet ist.
    var fullscreenTopInsets: ClosedRange<CGFloat> {
        hasIsland ? safeAreaTop...max(safeAreaTop, NotchIslandGeometry.bodyTop(self)) : safeAreaTop...safeAreaTop
    }
}

/// Lage der Anzeige an einer Kamera-Insel. Rein, ohne Bildschirm testbar; alle
/// Rahmen in globalen Cocoa-Koordinaten.
///
/// Links und rechts der Kamera gehört die Menüleiste den Menüs und
/// Statussymbolen (`auxiliaryTop…Area` reicht bis an die Kamera). Die Anzeige
/// belegt dort deshalb nur einen Hals um die Kamera, wie das Band an der
/// Notch; alles andere hängt unter der Menüleiste. Die System-Insel selbst
/// liegt immer über unseren Fenstern (eigene Ebene von macOS).
///
/// Zwei Verhältnisse stammen aus der Messung vom 18.11.2026
/// (`docs/features/notch.md`), weil das System die Werte nicht meldet. Sie
/// sind Anteile am Sicherheitsrand und skalieren mit jeder Auflösung.
enum NotchIslandGeometry {
    static let maxIslandAspect: CGFloat = 3
    /// Schwarzer Rand links und rechts der Kamera.
    static let cutoutMargin: CGFloat = 3
    /// Die Insel beginnt ein Fünftel des Sicherheitsrands unter der Oberkante
    /// (gemessen 8 von 40 pt). Das System meldet nur ihre Unterkante.
    static let topInsetRatio: CGFloat = 0.2
    /// Die Menüleiste ist ein Achtel höher als der Sicherheitsrand (gemessen
    /// 45 zu 40 pt). Gilt nur, solange sie ausgeblendet ist und keine Höhe meldet.
    static let menuBarRatio: CGFloat = 1.125

    /// Breite der Zeile mit `chipCount` Zählern: je Zähler 46 pt (Punkt, bis
    /// zu zwei Ziffern, Abstand) plus Rand. Ein Zähler passt unter den Hals,
    /// die Zeile ist dann genauso breit wie er.
    static func compactWidth(chipCount: Int, band: NotchIslandBand) -> CGFloat {
        max(band.width, 12 + CGFloat(max(0, chipCount)) * 46)
    }

    /// Abstand der Kapsel zur Oberkante des Bildschirms: die Oberkante der
    /// Insel, damit das Band oben nicht über sie hinausragt.
    static func topInset(_ screen: NotchScreenInfo) -> CGFloat {
        screen.safeAreaTop * topInsetRatio
    }

    /// Abstand der Oberkante des Körpers zur Oberkante des Bildschirms: die
    /// Unterkante der Menüleiste. Ist sie ausgeblendet, die Stelle, an der
    /// sie beim Einfahren endet; sonst läge der Körper dann unter ihr.
    static func bodyTop(_ screen: NotchScreenInfo) -> CGFloat {
        let measured = screen.measuredMenuBarHeight
        guard measured > 0 else { return (screen.safeAreaTop * menuBarRatio).rounded() }
        return max(screen.safeAreaTop, measured)
    }

    static func band(screen: NotchScreenInfo) -> NotchIslandBand {
        let inset = topInset(screen)
        return NotchIslandBand(
            width: screen.notchWidth + 2 * cutoutMargin,
            capsuleHeight: max(0, screen.safeAreaTop - inset),
            neckHeight: max(0, bodyTop(screen) - inset))
    }

    /// Wie an der Notch, nur mit dem Hals statt des Bands: Zähler, Chat-Name
    /// oder Liste hängen unter der Menüleiste. Die Zeile mit den Zählern ist
    /// so breit, wie die Zähler brauchen (die Insel ist schmaler als zwei).
    static func layout(screen: NotchScreenInfo, mode: NotchPanelMode) -> NotchLayout {
        let band = band(screen: screen)
        let bodyWidth: CGFloat
        var bodyHeight = NotchGeometry.chinHeight
        switch mode {
        case .compact(let chipCount):
            bodyWidth = compactWidth(chipCount: chipCount, band: band)
        case .alert:
            bodyWidth = max(band.width, NotchGeometry.alertWidth)
        case .expanded(let rows, let sections):
            bodyWidth = max(band.width, NotchGeometry.expandedMinWidth)
            bodyHeight += NotchGeometry.listHeight(rowCount: rows, sectionCount: sections)
        }
        let neck = CGRect(
            x: screen.notchCenterX - band.width / 2, y: windowTop(screen) - band.neckHeight,
            width: band.width, height: band.neckHeight)
        let body = CGRect(
            x: screen.notchCenterX - bodyWidth / 2, y: neck.minY - bodyHeight,
            width: bodyWidth, height: bodyHeight)
        return NotchLayout(frame: neck.union(body), band: neck, body: body)
    }

    /// Oberkante eines Fensters, das an der Insel hängt (Anzeige, Diktat,
    /// Controller): die Oberkante der Kapsel.
    static func windowTop(_ screen: NotchScreenInfo) -> CGFloat {
        screen.frame.maxY - topInset(screen)
    }
}
