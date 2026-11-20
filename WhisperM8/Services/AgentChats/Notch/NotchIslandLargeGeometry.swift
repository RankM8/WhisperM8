import CoreGraphics
import Foundation

/// Was die aufgeklappte große Form an der Kamera-Insel zeigt.
enum NotchIslandLargeKind: Equatable {
    /// „braucht dich“: klappt von selbst kurz auf.
    case alert
    /// Liste der Chats (Klick auf die Kapsel).
    case list(rowCount: Int, sectionCount: Int)
    /// Diktat mit Bedienknöpfen (Klick auf die Diktat-Kapsel).
    case dictation
    /// Aufnahme per Controller: dazu eine Zeile mit dem Ziel-Chat. Sie steht
    /// von selbst offen, weil Ziel und Modus ohne Klick sichtbar sein müssen.
    case dictationWithTarget
}

/// Die aufgeklappte Anzeige an einer Kamera-Insel: EINE schwarze Fläche mit
/// sehr runden Ecken, auf die Kamera zentriert, die aus der Insel in Breite
/// und Höhe wächst (wie Apples eigene aufgeklappte Insel). Kein Hals, kein
/// Kasten darunter.
///
/// Apples Insel liegt immer über unseren Fenstern. Was sie zeigt (Musik,
/// Mikrofon-Hinweis), steht deshalb oben in der Mitte der Form: Die Kopfzeile
/// lässt dort Platz (`slotLeading`, `slotTrailing`), eigener Inhalt steht
/// links und rechts davon und darunter.
struct NotchIslandLargeForm: Equatable {
    /// Rahmen der offenen Form in globalen Cocoa-Koordinaten.
    var frame: CGRect
    var cornerRadius: CGFloat
    /// Höhe der Kopfzeile: die Zeile, in der Apples Insel liegt.
    var headerHeight: CGFloat
    /// Platz für Apples Insel in der Kopfzeile, links und rechts der Mitte
    /// der Kamera (sie ist mit Inhalt nicht symmetrisch).
    var slotLeading: CGFloat
    var slotTrailing: CGFloat
    /// Nur Liste: Höhe des scrollenden Teils.
    var listHeight: CGFloat = 0

    var size: CGSize { frame.size }
}

/// Kopfzeile einer großen Form, deren Höhe sich aus ihrem Inhalt ergibt
/// (Controller-Insel): Höhe der Zeile und der Platz für Apples Insel.
struct NotchIslandLargeHeaderMetrics: Equatable {
    var height: CGFloat
    var slotLeading: CGFloat
    var slotTrailing: CGFloat
}

/// Umriss der Form in ihren eigenen Koordinaten: Mitte gegenüber der Mitte
/// der Kamera, Oberkante gegenüber der Oberkante der offenen Form. Offen ist
/// es die ganze Form, zu ist es die Kapsel, aus der sie wächst und in die sie
/// sich zurückzieht (Ruhe-Kapsel, abgesetzter Kreis, Diktat-Kapsel oder
/// Apples Insel selbst). Die Bewegung gleitet zwischen zwei Umrissen.
struct NotchIslandLargeOutline: Equatable {
    var centerOffset: CGFloat
    var top: CGFloat
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat

    /// Rechteck in einem Rahmen, dessen obere Mitte die Mitte der Kamera an
    /// der Oberkante der Form ist (Ursprung oben links).
    func rect(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.midX + centerOffset - width / 2, y: bounds.minY + top, width: width, height: height)
    }

    /// Zwischenstand der Bewegung (0 = dieser Umriss, 1 = `other`).
    func interpolated(to other: NotchIslandLargeOutline, progress: CGFloat) -> NotchIslandLargeOutline {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
        return NotchIslandLargeOutline(
            centerOffset: mix(centerOffset, other.centerOffset), top: mix(top, other.top),
            width: mix(width, other.width), height: mix(height, other.height), radius: mix(radius, other.radius))
    }
}

/// Maße und Lage der großen Form. Rein, ohne Bildschirm testbar.
///
/// Apples aufgeklappte Insel, gemessen am 19.11.2026 (macOS 27.2.1,
/// `docs/features/notch.md`): 286 × 152 pt, 6 pt unter der Oberkante, Ecken
/// rund 36 pt, Innenabstand 16 pt. Unsere Form übernimmt Oberkante und Ecken;
/// sie ist breiter, weil Chat-Namen sonst abgeschnitten würden.
enum NotchIslandLargeGeometry {
    /// Die Form beginnt dort, wo Apples Insel mit Inhalt beginnt: 6 von 40 pt
    /// Sicherheitsrand (in Ruhe beginnt die Insel bei 8 pt). So ragt Apples
    /// Insel nie oben über unsere Form hinaus.
    static let topRatio: CGFloat = 0.15
    static let cornerRadius: CGFloat = 36
    /// Innenabstand links und rechts.
    static let padding: CGFloat = 18
    /// Innenabstand der Kopfzeile links und rechts. Größer als `padding`:
    /// Die Kopfzeile liegt in der Zeile der runden oberen Ecken (36 pt);
    /// mit 18 pt säße ihr Inhalt in der Rundung und wirkte an den Rand
    /// gequetscht. Mit 28 pt steht er so weit von der Kante weg wie vom
    /// oberen Rand.
    static let headerInset: CGFloat = 28
    static let bottomPadding: CGFloat = 16
    /// Luft unter Apples Insel, bevor eigener Inhalt beginnt.
    static let headerGap: CGFloat = 8
    /// Abstand eigener Kopf-Inhalte zu Apples Insel.
    static let slotMargin: CGFloat = 8

    static let listWidth: CGFloat = 420
    static let alertWidth: CGFloat = 380
    static let alertHeight: CGFloat = 108
    static let dictationWidth: CGFloat = 420
    static let dictationHeight: CGFloat = 178
    /// Zeile „→ Ziel-Chat“ bei der Aufnahme per Controller.
    static let dictationTargetRowHeight: CGFloat = 28

    static let rowHeight: CGFloat = 56
    static let sectionHeaderHeight: CGFloat = 28
    static let footerHeight: CGFloat = 30
    /// Höhe der Zeile „Keine aktiven Chats“ in einer leeren Liste.
    static let emptyListHeight: CGFloat = 44
    /// Darüber scrollt die Liste.
    static let maxListHeight: CGFloat = 420
    /// Abstand der Form zum Bildschirmrand.
    static let screenMargin: CGFloat = 12
    /// Bedienknöpfe in der großen Form (Diktat): gut zu treffen.
    static let controlSize: CGFloat = 44
    /// Rand des Fensters um die Form (links, rechts, unten), damit die
    /// Federbewegung kurz überschwingen kann, ohne am Fensterrand
    /// abgeschnitten zu werden. Klicks nimmt der Rand nicht an.
    static let overshootMargin: CGFloat = 16

    /// Abstand der Form zur Oberkante des Bildschirms.
    static func topInset(_ screen: NotchScreenInfo) -> CGFloat {
        min(NotchIslandGeometry.topInset(screen), screen.safeAreaTop * topRatio)
    }

    /// Oberkante der Form (und ihrer Fenster) in globalen Cocoa-Koordinaten.
    static func windowTop(_ screen: NotchScreenInfo) -> CGFloat {
        screen.frame.maxY - topInset(screen)
    }

    /// So viel höher als die Kapsel in Ruhe beginnt die große Form.
    static func topGap(_ screen: NotchScreenInfo) -> CGFloat {
        max(0, NotchIslandGeometry.topInset(screen) - topInset(screen))
    }

    /// Kopfzeile: von der Oberkante der Form bis unter Apples Insel, plus Luft.
    static func headerHeight(_ screen: NotchScreenInfo) -> CGFloat {
        max(0, screen.safeAreaTop - topInset(screen)) + headerGap
    }

    /// Platz für Apples Insel in der Kopfzeile, je Seite ab der Mitte der
    /// Kamera: so weit, wie sie gerade reicht (Messung), mindestens ihre
    /// Breite in Ruhe, dazu ein kleiner Abstand. `reserve`: beim Diktat der
    /// Platz für den Mikrofon-Hinweis, auch bevor er gemessen ist.
    static func slot(
        screen: NotchScreenInfo, occupancy: NotchMenuBarOccupancy?,
        reserve: (leading: CGFloat, trailing: CGFloat)? = nil
    ) -> (leading: CGFloat, trailing: CGFloat) {
        let half = screen.notchWidth / 2
        var leading = half + NotchIslandGeometry.cutoutMargin
        var trailing = half + NotchIslandGeometry.cutoutMargin
        if let system = occupancy?.systemIsland {
            leading = max(leading, screen.notchCenterX - system.lowerBound)
            trailing = max(trailing, system.upperBound - screen.notchCenterX)
        }
        if let reserve {
            leading = max(leading, half + reserve.leading)
            trailing = max(trailing, half + reserve.trailing)
        }
        return (leading + slotMargin, trailing + slotMargin)
    }

    /// Kopfzeile für eine Form, deren Höhe der Inhalt bestimmt.
    static func header(screen: NotchScreenInfo, occupancy: NotchMenuBarOccupancy?) -> NotchIslandLargeHeaderMetrics {
        let slot = slot(screen: screen, occupancy: occupancy)
        return NotchIslandLargeHeaderMetrics(
            height: headerHeight(screen), slotLeading: slot.leading, slotTrailing: slot.trailing)
    }

    /// Höhe aller Zeilen und Zwischentitel einer Liste, ohne Begrenzung.
    static func listContentHeight(rowCount: Int, sectionCount: Int) -> CGFloat {
        guard rowCount > 0 else { return emptyListHeight }
        return CGFloat(rowCount) * rowHeight + CGFloat(max(0, sectionCount)) * sectionHeaderHeight
    }

    /// Die offene Form: auf die Kamera zentriert, Oberkante auf Höhe von
    /// Apples Insel. Bleibt im Bildschirm: Die Breite reicht höchstens bis
    /// an den Rand, die Liste scrollt, bevor sie unten herausragt.
    static func form(
        screen: NotchScreenInfo, kind: NotchIslandLargeKind, occupancy: NotchMenuBarOccupancy? = nil,
        reserve: (leading: CGFloat, trailing: CGFloat)? = nil
    ) -> NotchIslandLargeForm {
        let header = headerHeight(screen)
        let top = windowTop(screen)
        var width: CGFloat
        var height: CGFloat
        var listHeight: CGFloat = 0
        switch kind {
        case .alert:
            width = alertWidth
            height = alertHeight
        case .dictation:
            width = dictationWidth
            height = dictationHeight
        case .dictationWithTarget:
            width = dictationWidth
            height = dictationHeight + dictationTargetRowHeight
        case .list(let rows, let sections):
            width = listWidth
            let chrome = header + footerHeight + bottomPadding
            let available = top - screen.visibleFrame.minY - screenMargin - chrome
            listHeight = max(
                rowHeight, min(maxListHeight, listContentHeight(rowCount: rows, sectionCount: sections), available))
            if rows == 0 { listHeight = emptyListHeight }
            height = chrome + listHeight
        }
        // Auf die Kamera zentriert und trotzdem ganz im Bildschirm.
        let room = min(screen.notchCenterX - screen.frame.minX, screen.frame.maxX - screen.notchCenterX) - screenMargin
        width = max(0, min(width, 2 * room))
        let slot = slot(screen: screen, occupancy: occupancy, reserve: reserve)
        return NotchIslandLargeForm(
            frame: CGRect(x: screen.notchCenterX - width / 2, y: top - height, width: width, height: height),
            cornerRadius: min(cornerRadius, height / 2, width / 2),
            headerHeight: header, slotLeading: slot.leading, slotTrailing: slot.trailing, listHeight: listHeight)
    }

    /// Apples Insel selbst: in Ruhe die Kapsel um die Kamera, mit Inhalt so
    /// breit und hoch, wie die Messung sie zeigt. Aus ihr wächst die Form,
    /// wenn vorher nichts von uns in der Menüleiste stand.
    static func systemIslandFrame(screen: NotchScreenInfo, occupancy: NotchMenuBarOccupancy?) -> CGRect {
        if let system = occupancy?.systemIsland {
            let insets = occupancy?.systemIslandInsets ?? topInset(screen)...screen.safeAreaTop
            return CGRect(
                x: system.lowerBound, y: screen.frame.maxY - insets.upperBound,
                width: system.upperBound - system.lowerBound, height: insets.upperBound - insets.lowerBound)
        }
        let band = NotchIslandGeometry.band(screen: screen)
        return CGRect(
            x: screen.notchCenterX - band.width / 2, y: NotchIslandGeometry.windowTop(screen) - band.capsuleHeight,
            width: band.width, height: band.capsuleHeight)
    }

    /// Umriss der offenen Form.
    static func openOutline(_ form: NotchIslandLargeForm) -> NotchIslandLargeOutline {
        NotchIslandLargeOutline(
            centerOffset: 0, top: 0, width: form.frame.width, height: form.frame.height, radius: form.cornerRadius)
    }

    /// Umriss einer Kapsel (globaler Rahmen) in den Koordinaten der Form.
    static func outline(of capsule: CGRect, screen: NotchScreenInfo) -> NotchIslandLargeOutline {
        NotchIslandLargeOutline(
            centerOffset: capsule.midX - screen.notchCenterX, top: windowTop(screen) - capsule.maxY,
            width: capsule.width, height: capsule.height, radius: min(capsule.width, capsule.height) / 2)
    }

    /// Kapsel, aus der die Form wächst und in die sie zurückgeht: was in
    /// Ruhe in der Menüleiste steht (Kapsel mit Zeichen und Zahl bzw. der
    /// abgesetzte Kreis), sonst Apples Insel selbst.
    static func seedFrame(
        screen: NotchScreenInfo, band: NotchIslandBand, presentation: NotchIslandPresentation,
        occupancy: NotchMenuBarOccupancy?
    ) -> CGRect {
        guard presentation != .hidden else { return systemIslandFrame(screen: screen, occupancy: occupancy) }
        return NotchIslandGeometry.layout(screen: screen, mode: .compact(chipCount: 0), band: band).frame
    }

    /// Fenster für eine Form, oder für zwei zugleich (Übergang von der einen
    /// zur anderen, etwa Hinweis zur Liste): Alle Formen sind auf die Kamera
    /// zentriert und beginnen an derselben Oberkante, das Fenster auch.
    /// `margin`: Rand links, rechts und unten, in dem die Bewegung kurz
    /// überschwingen darf.
    static func canvas(_ form: CGRect, _ other: CGRect? = nil, margin: CGFloat = 0) -> CGRect {
        let width = max(form.width, other?.width ?? 0) + 2 * margin
        let height = max(form.height, other?.height ?? 0) + margin
        return CGRect(x: form.midX - width / 2, y: form.maxY - height, width: width, height: height)
    }

    /// Klickfläche in einem Fenster, dessen obere Mitte die Mitte der Kamera
    /// an der Oberkante der Form ist (Koordinaten der Ansicht, oben links).
    /// Was im Fenster daneben liegt, gehört weiter der Menüleiste.
    static func hitFrame(of outline: NotchIslandLargeOutline, inCanvasOfSize canvas: CGSize) -> CGRect {
        outline.rect(in: CGRect(origin: .zero, size: canvas))
    }
}
