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

/// Band der Anzeige an einer Kamera-Insel, in Punkten: die schwarze Kapsel um
/// die Kamera. Diktat und Controller-Insel nutzen sie als schmalen Hals
/// (Aussparung plus Rand); die Status-Anzeige verbreitert sie seitlich um
/// Flügel für ein Zeichen und eine Zahl, wenn dort nachweislich Platz ist
/// (`NotchIslandGeometry.presentation`). Hinweis, Liste und Diktat hängen
/// unter der Menüleiste.
struct NotchIslandBand: Equatable {
    /// Breite des Bands: die Aussparung plus beide Flügel.
    var width: CGFloat
    /// Höhe der Kapsel um die Kamera (das Band, solange nichts darunter hängt).
    var capsuleHeight: CGFloat
    /// Höhe des Bands von der Oberkante der Kapsel bis zum Körper unter der Menüleiste.
    var neckHeight: CGFloat
    /// Schwarzer Bereich links bzw. rechts der Aussparung. Ohne Inhalt nur
    /// der schmale Rand (`NotchIslandGeometry.cutoutMargin`) bzw. so weit,
    /// wie Apples Insel gerade selbst reicht (Mikrofon-Hinweis).
    var leadingWing: CGFloat = NotchIslandGeometry.cutoutMargin
    var trailingWing: CGFloat = NotchIslandGeometry.cutoutMargin
    /// Äußerer Teil des Flügels, in dem das Zeichen bzw. die Zahl steht
    /// (0 ohne Inhalt auf dieser Seite).
    var leadingContent: CGFloat = 0
    var trailingContent: CGFloat = 0
    /// Neben dem Zeichen steht seine Zahl (kompakt); sonst das Zeichen allein.
    var showsValue = false
    /// Zeigt Apples Insel selbst etwas, steht unser Zeichen in Ruhe als
    /// eigener kleiner Kreis neben ihr, mit Abstand (wie die abgesetzte
    /// minimale Darstellung bei zwei Live Activities). Rahmen in globalen
    /// Cocoa-Koordinaten; `nil` sonst.
    var detachedFrame: CGRect? = nil

    var topRadius: CGFloat { capsuleHeight / 2 }
    var hasLeadingContent: Bool { leadingContent > 0 }
    var hasTrailingContent: Bool { trailingContent > 0 }
    /// Mitte des Bands gegenüber der Mitte der Kamera (nur bei einem
    /// einzelnen Flügel ungleich 0).
    var centerOffset: CGFloat { (trailingWing - leadingWing) / 2 }
    /// Breite der Aussparung selbst.
    var cutoutWidth: CGFloat { max(0, width - leadingWing - trailingWing) }
}

/// Das eine Zeichen samt Zahl der kompakten Anzeige: der wichtigste Zustand.
/// Wartet ein Chat auf dich, zählt das zuerst; dann Fehler, Arbeit, frisch
/// fertig. Ist nichts los, gibt es kein Zeichen und die Anzeige bleibt weg.
struct NotchIslandSignal: Equatable {
    enum Kind: Equatable { case waiting, errored, working, done }

    var kind: Kind
    var count: Int

    init(kind: Kind, count: Int) {
        self.kind = kind
        self.count = count
    }

    init?(summary: NotchSummary) {
        if summary.waiting > 0 {
            self.init(kind: .waiting, count: summary.waiting)
        } else if summary.errored > 0 {
            self.init(kind: .errored, count: summary.errored)
        } else if summary.working > 0 {
            self.init(kind: .working, count: summary.working)
        } else if summary.freshDone > 0 {
            self.init(kind: .done, count: summary.freshDone)
        } else {
            return nil
        }
    }

    /// Höchstens zwei Ziffern, damit der Flügel schmal bleibt.
    var text: String { String(min(count, 99)) }
    var digits: Int { count > 9 ? 2 : 1 }
}

enum NotchIslandSide: Equatable { case leading, trailing }

/// Die Stufen der Anzeige in der Menüleiste, nach Apples Live Activities
/// (HIG): kompakt mit Zeichen und Zahl zusammen auf einer Seite der Kamera,
/// minimal mit nur dem Zeichen, oder nichts.
enum NotchIslandPresentation: Equatable {
    case hidden
    case minimal(NotchIslandSide)
    case compact(NotchIslandSide)
}

/// Die kompakte Diktat-Kapsel in der Menüleiste neben der Kamera-Insel:
/// Wellenform und Zeit zusammen in einer eigenen kleinen Kapsel, mit Abstand
/// neben Apples Insel (die beim Diktat selbst den Mikrofon-Hinweis zeigt und
/// über unserem Fenster liegt).
struct NotchIslandDictationCapsule: Equatable {
    var side: NotchIslandSide
    /// `false`: nur die Wellenform (minimal).
    var showsClock: Bool
    var width: CGFloat
    /// Mitte der Kapsel gegenüber der Mitte der Kamera.
    var offset: CGFloat

    /// Rahmen in globalen Cocoa-Koordinaten.
    func frame(screen: NotchScreenInfo) -> CGRect {
        let band = NotchIslandGeometry.band(screen: screen)
        return CGRect(
            x: screen.notchCenterX + offset - width / 2,
            y: NotchIslandGeometry.windowTop(screen) - band.capsuleHeight,
            width: width, height: band.capsuleHeight)
    }
}

/// Gemessene Belegung der Menüleiste: Rahmen der Menüs der vorderen App und
/// der Statussymbole, in globalen Koordinaten (es zählt nur die x-Achse).
/// Ohne Messung (keine Berechtigung für Bedienungshilfen) gibt es keinen
/// Wert, und die Anzeige bleibt aus der Menüleiste heraus.
struct NotchMenuBarOccupancy: Equatable {
    var frames: [CGRect]
    /// Breite von Apples Insel, wenn sie gerade selbst etwas zeigt (etwa den
    /// Mikrofon-Hinweis) und deshalb über die Aussparung hinausreicht; `nil`
    /// in Ruhe. Ihr Fenster liegt immer über unserem: Was wir dort zeichnen,
    /// ist verdeckt, eigener Inhalt gehört außen daneben.
    var systemIsland: ClosedRange<CGFloat>? = nil
    /// Ober- und Unterkante von Apples Insel als Abstand zur Oberkante des
    /// Bildschirms (mit Inhalt ist sie etwas höher als in Ruhe).
    var systemIslandInsets: ClosedRange<CGFloat>? = nil
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
/// wird dort wie Apples Insel nur seitlich breiter, und nur so weit, wie die
/// Messung freien Platz belegt (`presentation`); ohne Platz oder ohne Messung
/// bleibt es beim Hals um die Kamera. Hinweis und Liste hängen unter der
/// Menüleiste. Die System-Insel selbst liegt immer über unseren Fenstern
/// (eigene Ebene von macOS).
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

    /// Platz für das Zeichen allein. Mit dem Rand um die Kamera ist der
    /// Flügel 26 pt breit, so viel wie bei Apples eigener Insel mit
    /// Mikrofon-Hinweis (gemessen 111,5 pt gesamt, je Seite 26).
    static let glyphContent: CGFloat = 23
    /// Abstand, den die Kapsel zu Menüs und Statussymbolen hält.
    static let menuClearance: CGFloat = 6
    /// Schwarzer Rand um Apples Insel, wenn sie breiter ist als die Aussparung.
    static let systemRim: CGFloat = 2
    /// Abstand des abgesetzten Kreises zu Apples Insel.
    static let detachedGap: CGFloat = 6

    /// Platz für Zeichen und Zahl nebeneinander: 10 pt bis zum runden Ende,
    /// Zeichen 9, Abstand 5, je Ziffer 7,5, dann 5 bis zum Rand um die Kamera.
    static func compactContent(digits: Int) -> CGFloat { digits > 1 ? 45 : 37 }

    /// Freier Platz links und rechts der Aussparung bis zum nächsten
    /// gemessenen Rahmen (bzw. bis zum Bildschirmrand).
    static func freeSpace(screen: NotchScreenInfo, occupancy: NotchMenuBarOccupancy) -> (leading: CGFloat, trailing: CGFloat) {
        let cutoutMinX = screen.notchCenterX - screen.notchWidth / 2
        let cutoutMaxX = screen.notchCenterX + screen.notchWidth / 2
        var leading = max(0, cutoutMinX - screen.frame.minX)
        var trailing = max(0, screen.frame.maxX - cutoutMaxX)
        for frame in occupancy.frames where frame.width > 0 {
            guard frame.maxX > screen.frame.minX, frame.minX < screen.frame.maxX else { continue }
            if frame.minX < cutoutMinX { leading = min(leading, max(0, cutoutMinX - frame.maxX)) }
            if frame.maxX > cutoutMaxX { trailing = min(trailing, max(0, frame.minX - cutoutMaxX)) }
        }
        return (leading, trailing)
    }

    /// Schwarzer Bereich neben der Aussparung ohne eigenen Inhalt: der
    /// schmale Rand, oder so weit, wie Apples Insel gerade reicht. Nie weiter
    /// als bis zum nächsten Menü oder Statussymbol.
    static func baseWings(screen: NotchScreenInfo, occupancy: NotchMenuBarOccupancy?) -> (leading: CGFloat, trailing: CGFloat) {
        guard let occupancy, let system = occupancy.systemIsland else { return (cutoutMargin, cutoutMargin) }
        let cutoutMinX = screen.notchCenterX - screen.notchWidth / 2
        let cutoutMaxX = screen.notchCenterX + screen.notchWidth / 2
        let free = freeSpace(screen: screen, occupancy: occupancy)
        let leading = min(cutoutMinX - system.lowerBound + systemRim, free.leading)
        let trailing = min(system.upperBound - cutoutMaxX + systemRim, free.trailing)
        return (max(cutoutMargin, leading), max(cutoutMargin, trailing))
    }

    /// Welche Stufe passt: kompakt, wenn auf einer Seite Zeichen und Zahl
    /// samt Abstand Platz haben (links zuerst, sonst rechts); sonst das
    /// Zeichen allein auf der Seite mit Platz; sonst nichts. Zeigt Apples
    /// Insel gerade selbst etwas, bleibt es beim Zeichen allein (wie bei
    /// zwei Live Activities, HIG), abgesetzt neben ihr. Ohne Zeichen (nichts
    /// los) und ohne Messung nichts.
    static func presentation(
        signal: NotchIslandSignal?, screen: NotchScreenInfo, occupancy: NotchMenuBarOccupancy?
    ) -> NotchIslandPresentation {
        guard let signal, let occupancy, screen.hasIsland else { return .hidden }
        let free = freeSpace(screen: screen, occupancy: occupancy)
        let base = baseWings(screen: screen, occupancy: occupancy)
        if occupancy.systemIsland == nil {
            let content = compactContent(digits: signal.digits) + menuClearance
            if free.leading >= base.leading + content { return .compact(.leading) }
            if free.trailing >= base.trailing + content { return .compact(.trailing) }
        }
        // Neben Apples aktiver Insel: Abstand plus ein Kreis in ihrer Höhe.
        let glyph = occupancy.systemIsland == nil
            ? glyphContent + menuClearance
            : detachedGap + detachedSize(screen: screen, occupancy: occupancy) + menuClearance
        if free.leading >= base.leading + glyph { return .minimal(.leading) }
        if free.trailing >= base.trailing + glyph { return .minimal(.trailing) }
        return .hidden
    }

    // MARK: Diktat

    /// Apples Insel mit Mikrofon-Hinweis (Punkt und Mikrofon-Zeichen, 143 pt)
    /// reicht links 36,5 und rechts 47,5 pt über die Aussparung hinaus
    /// (gemessen bei 40 pt Sicherheitsrand; mit dem Punkt allein sind es je
    /// 26,25 pt). So viel Platz bleibt ihr von Anfang an, damit die
    /// Diktat-Kapsel nicht springt, wenn der Hinweis erscheint.
    static let microphoneReserveLeadingRatio: CGFloat = 0.9125
    static let microphoneReserveTrailingRatio: CGFloat = 1.1875
    /// Breite der Diktat-Kapsel: Wellenform und Zeit bzw. nur die Wellenform;
    /// mit Raute für wartende Chats etwas mehr.
    static let dictationCompactWidth: CGFloat = 96
    static let dictationMinimalWidth: CGFloat = 48
    static let dictationBadgeWidth: CGFloat = 14
    /// Platz, den die Diktat-Kapsel Apples Insel je Seite lässt: der
    /// Mikrofon-Hinweis, oder mehr, wenn die Messung eine breitere Insel
    /// zeigt. `previous`: der Wert bisher in diesem Diktat; die Kapsel rückt
    /// nur nach außen, nie zurück (kein Hin und Her).
    static func dictationReserve(
        screen: NotchScreenInfo, occupancy: NotchMenuBarOccupancy?,
        previous: (leading: CGFloat, trailing: CGFloat)? = nil
    ) -> (leading: CGFloat, trailing: CGFloat) {
        var leading = max(screen.safeAreaTop * microphoneReserveLeadingRatio, previous?.leading ?? 0)
        var trailing = max(screen.safeAreaTop * microphoneReserveTrailingRatio, previous?.trailing ?? 0)
        if let system = occupancy?.systemIsland {
            leading = max(leading, screen.notchCenterX - screen.notchWidth / 2 - system.lowerBound)
            trailing = max(trailing, system.upperBound - (screen.notchCenterX + screen.notchWidth / 2))
        }
        return (leading, trailing)
    }

    /// Wo die Diktat-Kapsel steht: mit Zeit, wenn auf einer Seite Platz ist
    /// (links zuerst), sonst nur die Wellenform, sonst gar nicht (`nil`: Das
    /// Diktat hängt dann wie früher unter der Menüleiste, eine laufende
    /// Aufnahme bleibt immer sichtbar). Ohne Messung erscheint die schmalste
    /// Form links: Der Nutzer hat das Diktat selbst ausgelöst, es dauert
    /// Sekunden, und ohne Anzeige wäre eine laufende Aufnahme unsichtbar.
    static func dictationCapsule(
        screen: NotchScreenInfo, occupancy: NotchMenuBarOccupancy?, hasBadge: Bool = false,
        reserve: (leading: CGFloat, trailing: CGFloat)? = nil
    ) -> NotchIslandDictationCapsule? {
        guard screen.hasIsland else { return nil }
        let reserve = reserve ?? dictationReserve(screen: screen, occupancy: occupancy)
        let badge = hasBadge ? dictationBadgeWidth : 0
        func capsule(_ side: NotchIslandSide, clock: Bool) -> NotchIslandDictationCapsule {
            let width = (clock ? dictationCompactWidth : dictationMinimalWidth) + badge
            let inner = screen.notchWidth / 2 + (side == .leading ? reserve.leading : reserve.trailing) + detachedGap
            return NotchIslandDictationCapsule(
                side: side, showsClock: clock, width: width,
                offset: (side == .leading ? -1 : 1) * (inner + width / 2))
        }
        guard let occupancy else { return capsule(.leading, clock: false) }
        let free = freeSpace(screen: screen, occupancy: occupancy)
        for clock in [true, false] {
            for side in [NotchIslandSide.leading, .trailing] {
                let candidate = capsule(side, clock: clock)
                let needed = abs(candidate.offset) + candidate.width / 2 - screen.notchWidth / 2 + menuClearance
                if (side == .leading ? free.leading : free.trailing) >= needed { return candidate }
            }
        }
        return nil
    }

    /// Durchmesser des abgesetzten Kreises: so hoch wie Apples Insel gerade ist.
    static func detachedSize(screen: NotchScreenInfo, occupancy: NotchMenuBarOccupancy) -> CGFloat {
        let insets = occupancy.systemIslandInsets ?? topInset(screen)...screen.safeAreaTop
        return max(0, insets.upperBound - insets.lowerBound)
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

    /// Band mit dem, was neben der Kamera gemessen ist: der Hals, so breit
    /// wie Apples Insel gerade reicht, dazu außen die Flügel der gewählten
    /// Stufe. Ohne Messung und ohne Stufe der schmale Hals (`band(screen:)`).
    static func band(
        screen: NotchScreenInfo, occupancy: NotchMenuBarOccupancy?,
        presentation: NotchIslandPresentation = .hidden, digits: Int = 1
    ) -> NotchIslandBand {
        var band = band(screen: screen)
        let base = baseWings(screen: screen, occupancy: occupancy)
        if let occupancy, occupancy.systemIsland != nil, case .minimal(let side) = presentation {
            // Abgesetzt: Das Band bleibt der Hals unter Apples Insel, das
            // Zeichen steht in Ruhe als Kreis daneben.
            let size = detachedSize(screen: screen, occupancy: occupancy)
            let top = occupancy.systemIslandInsets?.lowerBound ?? topInset(screen)
            let cutoutMinX = screen.notchCenterX - screen.notchWidth / 2
            let cutoutMaxX = screen.notchCenterX + screen.notchWidth / 2
            let minX = side == .leading
                ? cutoutMinX - base.leading - detachedGap - size : cutoutMaxX + base.trailing + detachedGap
            band.detachedFrame = CGRect(x: minX, y: screen.frame.maxY - top - size, width: size, height: size)
            band.leadingWing = base.leading
            band.trailingWing = base.trailing
            band.width = screen.notchWidth + band.leadingWing + band.trailingWing
            return band
        }
        switch presentation {
        case .hidden:
            break
        case .compact(.leading):
            band.leadingContent = compactContent(digits: digits)
            band.showsValue = true
        case .compact(.trailing):
            band.trailingContent = compactContent(digits: digits)
            band.showsValue = true
        case .minimal(.leading):
            band.leadingContent = glyphContent
        case .minimal(.trailing):
            band.trailingContent = glyphContent
        }
        band.leadingWing = base.leading + band.leadingContent
        band.trailingWing = base.trailing + band.trailingContent
        band.width = screen.notchWidth + band.leadingWing + band.trailingWing
        return band
    }

    /// Ruhe (`compact`): nur die Kapsel in der Menüleiste, so breit wie ihr
    /// Band, nichts darunter. Hinweis und Liste: Das Band läuft als Hals bis
    /// unter die Menüleiste, dort hängt der Körper mit Chat-Name bzw. Liste,
    /// mittig unter der Kamera. `band`: das Band der Status-Anzeige; ohne
    /// Angabe der schmale Hals.
    static func layout(screen: NotchScreenInfo, mode: NotchPanelMode, band: NotchIslandBand? = nil) -> NotchLayout {
        let band = band ?? self.band(screen: screen)
        let bandMinX = screen.notchCenterX - screen.notchWidth / 2 - band.leadingWing
        let top = windowTop(screen)
        let bodyWidth: CGFloat
        var bodyHeight = NotchGeometry.chinHeight
        switch mode {
        case .compact:
            if let detached = band.detachedFrame {
                return NotchLayout(
                    frame: detached, band: detached, body: CGRect(x: detached.midX, y: detached.minY, width: 0, height: 0))
            }
            let capsule = CGRect(x: bandMinX, y: top - band.capsuleHeight, width: band.width, height: band.capsuleHeight)
            return NotchLayout(
                frame: capsule, band: capsule, body: CGRect(x: capsule.midX, y: capsule.minY, width: 0, height: 0))
        case .alert:
            bodyWidth = max(band.width, NotchGeometry.alertWidth)
        case .expanded(let rows, let sections):
            bodyWidth = max(band.width, NotchGeometry.expandedMinWidth)
            bodyHeight += NotchGeometry.listHeight(rowCount: rows, sectionCount: sections)
        }
        let neck = CGRect(x: bandMinX, y: top - band.neckHeight, width: band.width, height: band.neckHeight)
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
