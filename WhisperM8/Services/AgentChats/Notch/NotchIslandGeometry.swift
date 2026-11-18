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

/// Maße der Anzeige an einer Kamera-Insel, in Punkten. Die Anzeige legt eine
/// schwarze Kapsel um die Kamera; Zähler stehen links und rechts daneben,
/// alles Breitere hängt an einem Hals unter der Menüleiste.
struct NotchIslandBand: Equatable {
    /// Breite der Aussparung laut System.
    var cutoutWidth: CGFloat
    /// Höhe der Kapsel um die Kamera (Ruhe).
    var capsuleHeight: CGFloat
    /// Höhe des Bands von der Kapsel-Oberkante bis zum Körper unter der Menüleiste.
    var neckHeight: CGFloat
    /// Platz links bzw. rechts neben der Aussparung (Zähler oder nur der Rand).
    var leadingSlot: CGFloat
    var trailingSlot: CGFloat

    var width: CGFloat { leadingSlot + cutoutWidth + trailingSlot }
    /// Mitte des Bands gegen die Mitte der Aussparung (Zähler nur auf einer
    /// Seite: das Band wächst nur dorthin).
    var centerOffset: CGFloat { (trailingSlot - leadingSlot) / 2 }
    var topRadius: CGFloat { capsuleHeight / 2 }
    /// Breite, um die Aussparung zentriert, in die das Band ganz passt.
    var centeredWidth: CGFloat { cutoutWidth + 2 * max(leadingSlot, trailingSlot) }
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

    /// Wo ein Vollbild-Fenster unter der Kamera beginnt: an der Notch an ihrer
    /// Unterkante, an der Insel unter der Menüleiste.
    var fullscreenTopInset: CGFloat {
        hasIsland ? NotchIslandGeometry.bodyTop(self) : safeAreaTop
    }
}

/// Lage der Anzeige an einer Kamera-Insel. Rein, ohne Bildschirm testbar; alle
/// Rahmen in globalen Cocoa-Koordinaten.
///
/// Die System-Insel liegt immer über unseren Fenstern (eigene Ebene von
/// macOS). Die Anzeige legt deshalb nur Schwarz um sie herum: eine Kapsel in
/// der Menüleiste, die die Insel einschließt, und für Hinweis, Liste und
/// Diktat einen Körper unter der Menüleiste. Die Menüleiste bleibt bis auf die
/// Kapsel frei.
enum NotchIslandGeometry {
    static let maxIslandAspect: CGFloat = 3
    /// Schwarzer Rand neben der Kamera, wenn daneben nichts steht.
    static let cutoutMargin: CGFloat = 3
    /// Abstand der Zähler zur Kamera. Rechts blendet das System dort die
    /// Mikrofon-Anzeige ein; die Zähler stehen deshalb nicht direkt an.
    static let slotInnerGap: CGFloat = 10
    /// Abstand der Zähler zum runden Ende der Kapsel.
    static let slotOuterPadding: CGFloat = 11
    /// Platz je Zähler (Punkt und bis zu zwei Ziffern).
    static let chipWidth: CGFloat = 28
    static let chipSpacing: CGFloat = 10

    /// Abstand der Kapsel zur Oberkante des Bildschirms. Die Kapsel sitzt in
    /// der Menüleiste so, dass über ihr so viel Luft bleibt wie unter der
    /// Kamera (Menüleiste minus Sicherheitsrand). Meldet das System keine
    /// Menüleiste (ausgeblendet), gilt ein Achtel des Sicherheitsrands.
    static func topInset(_ screen: NotchScreenInfo) -> CGFloat {
        let below = screen.measuredMenuBarHeight - screen.safeAreaTop
        let inset = below >= 1 ? below : (screen.safeAreaTop / 8).rounded()
        return min(max(inset, 2), screen.safeAreaTop / 4)
    }

    /// Abstand der Oberkante des Körpers zur Oberkante des Bildschirms: unter
    /// der Menüleiste, mindestens unter der Kamera.
    static func bodyTop(_ screen: NotchScreenInfo) -> CGFloat {
        max(screen.safeAreaTop, screen.measuredMenuBarHeight)
    }

    /// Zähler links und rechts der Kamera: gleichmäßig verteilt, der erste
    /// links (arbeitet, wartet, Fehler, fertig in dieser Reihenfolge).
    static func chipSplit(chipCount: Int) -> (leading: Int, trailing: Int) {
        let count = max(0, chipCount)
        return (leading: (count + 1) / 2, trailing: count / 2)
    }

    static func slotWidth(chips: Int) -> CGFloat {
        guard chips > 0 else { return cutoutMargin }
        return slotInnerGap + CGFloat(chips) * chipWidth + CGFloat(chips - 1) * chipSpacing + slotOuterPadding
    }

    /// Band für `chipCount` sichtbare Zähler (0: nur die Kamera mit Rand).
    static func band(screen: NotchScreenInfo, chipCount: Int = 0) -> NotchIslandBand {
        let inset = topInset(screen)
        let split = chipSplit(chipCount: chipCount)
        return NotchIslandBand(
            cutoutWidth: screen.notchWidth,
            capsuleHeight: max(0, screen.safeAreaTop - inset),
            neckHeight: max(0, bodyTop(screen) - inset),
            leadingSlot: slotWidth(chips: split.leading),
            trailingSlot: slotWidth(chips: split.trailing))
    }

    /// Ruhe: nur die Kapsel in der Menüleiste. Hinweis und Liste: Die Kapsel
    /// wird zum Hals, darunter hängt der Körper unter der Menüleiste. Das
    /// Fenster ist immer um die Kamera zentriert, damit die Zähler beim
    /// Wechsel der Zustände stehen bleiben; neben dem Band ist es durchsichtig.
    static func layout(screen: NotchScreenInfo, mode: NotchPanelMode, chipCount: Int) -> NotchLayout {
        let band = band(screen: screen, chipCount: chipCount)
        let top = screen.frame.maxY - topInset(screen)
        let centerX = screen.notchCenterX
        let bandMinX = centerX - band.cutoutWidth / 2 - band.leadingSlot

        let bodyWidth: CGFloat
        let bodyHeight: CGFloat
        switch mode {
        case .compact:
            let capsule = CGRect(x: bandMinX, y: top - band.capsuleHeight, width: band.width, height: band.capsuleHeight)
            let frame = CGRect(
                x: centerX - band.centeredWidth / 2, y: capsule.minY,
                width: band.centeredWidth, height: capsule.height)
            return NotchLayout(
                frame: frame, band: capsule,
                body: CGRect(x: capsule.minX, y: capsule.minY, width: capsule.width, height: 0))
        case .alert:
            bodyWidth = max(band.centeredWidth, NotchGeometry.alertWidth)
            bodyHeight = NotchGeometry.chinHeight
        case .expanded(let rows, let sections):
            bodyWidth = max(band.centeredWidth, NotchGeometry.expandedMinWidth)
            bodyHeight = NotchGeometry.listHeight(rowCount: rows, sectionCount: sections)
        }
        let neck = CGRect(x: bandMinX, y: top - band.neckHeight, width: band.width, height: band.neckHeight)
        let body = CGRect(x: centerX - bodyWidth / 2, y: neck.minY - bodyHeight, width: bodyWidth, height: bodyHeight)
        return NotchLayout(frame: neck.union(body), band: neck, body: body)
    }

    /// Oberkante eines Fensters, das an der Insel hängt (Diktat, Controller):
    /// die Oberkante der Kapsel.
    static func windowTop(_ screen: NotchScreenInfo) -> CGFloat {
        screen.frame.maxY - topInset(screen)
    }
}
