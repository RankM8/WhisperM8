import CoreGraphics
import Foundation

/// Was die vereinte Pille an einer Stelle zeigt — immer nur eins, in dieser
/// Reihenfolge: Insel vor Diktat vor offener Liste vor Hinweis „braucht dich“
/// vor Ruhe. Rein, damit die Regel ohne Fenster testbar ist.
enum UnifiedPillContent: Equatable {
    case hidden
    case rest
    case alert
    case list
    case dictation
    case island
}

/// Zustand einer Stelle (Bildschirm), aus dem die Priorität entscheidet.
struct UnifiedPillSituation: Equatable {
    /// Die Controller-Insel steht auf diesem Bildschirm.
    var island = false
    /// Das Diktat zeigt sich auf diesem Bildschirm.
    var dictation = false
    /// Die Statusliste ist hier aufgeklappt.
    var list = false
    /// Ein „braucht dich“-Hinweis läuft.
    var alert = false
    /// Der Chat-Status ist an (Einstellung und Kill-Switch).
    var statusActive = true
    /// Die Ruhe-Anzeige steht hier überhaupt (Pille immer, Notch nur bei
    /// Aktivität).
    var restVisible = true
    /// Vollbild-App im Vordergrund: Ruhe, Liste und Hinweis weg; Diktat und
    /// Insel bleiben.
    var fullscreen = false
}

enum UnifiedPillPriority {
    static func content(for situation: UnifiedPillSituation) -> UnifiedPillContent {
        if situation.island { return .island }
        if situation.dictation { return .dictation }
        guard situation.statusActive, !situation.fullscreen else { return .hidden }
        if situation.list { return .list }
        if situation.alert { return .alert }
        return situation.restVisible ? .rest : .hidden
    }
}

/// Wartende Chats und Fehler, solange das Diktat die Pille belegt: als Raute
/// bzw. Ring ganz links. „Arbeitet“ und „fertig“ fallen weg. `nil`, wenn
/// nichts auf dich wartet.
struct DictationStatusBadge: Equatable {
    var waiting: Int
    var errored: Int

    init?(waiting: Int, errored: Int) {
        guard waiting > 0 || errored > 0 else { return nil }
        self.waiting = waiting
        self.errored = errored
    }

    init?(summary: NotchSummary) {
        self.init(waiting: summary.waiting, errored: summary.errored)
    }
}

/// Wo sich ein Diktat zeigt (Entscheidung: dort, wo du tippst).
enum DictationPillPlacement: Equatable {
    /// An der Notch dieses Bildschirms, schwarz wie die Hardware, fest.
    case notch(NotchScreenInfo)
    /// Als Pille um diesen Mittelpunkt (gemerkte Lage des Bildschirms oder
    /// oben mittig).
    case pill(NotchScreenInfo, center: CGPoint)

    var screen: NotchScreenInfo {
        switch self {
        case .notch(let screen), .pill(let screen, _): return screen
        }
    }

    var isNotch: Bool {
        if case .notch = self { return true }
        return false
    }

    /// Bildschirm des vorderen Fensters, ersatzweise der Maus, sonst der mit
    /// der Menüleiste. Mit Notch an der Notch, sonst an der gemerkten Lage.
    static func resolve(
        frontWindowDisplayID: UInt32?,
        mouseDisplayID: UInt32?,
        mainDisplayID: UInt32?,
        screens: [NotchScreenInfo],
        positions: [String: NotchPillPosition]
    ) -> DictationPillPlacement? {
        func screen(_ id: UInt32?) -> NotchScreenInfo? {
            id.flatMap { id in screens.first { $0.displayID == id } }
        }
        guard let target = screen(frontWindowDisplayID) ?? screen(mouseDisplayID) ?? screen(mainDisplayID)
            ?? screens.first else { return nil }
        if target.hasNotch { return .notch(target) }
        return .pill(target, center: NotchPillPlacement.center(target, stored: positions[target.pillStorageKey]))
    }

    /// Bildschirm eines Fensters: der mit der größten Überlappung (Cocoa-Koordinaten).
    static func displayID(containing rect: CGRect, screens: [NotchScreenInfo]) -> UInt32? {
        screens
            .map { ($0.displayID, $0.frame.intersection(rect)) }
            .filter { !$0.1.isNull && !$0.1.isEmpty }
            .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?
            .0
    }
}

/// Geometrie der vereinten Pille: Zustandswechsel wachsen um die Mitte, nur
/// das Darüberfahren beim Diktat klappt nach links auf (rechte Kante bleibt).
enum UnifiedPillGeometry {
    /// Rand rund um die Pille für den gezeichneten Schatten (wie die
    /// Diktat-Pille, `OverlayFrameResolver.contentMargin`).
    static let shadowMargin: CGFloat = OverlayFrameResolver.contentMargin
    /// Breite des Fensters der Status-Pille: Platz für die breiteste Form
    /// (Liste) samt Schattenrand.
    static let statusPanelWidth: CGFloat = NotchGeometry.pillExpandedWidth + 2 * shadowMargin

    /// Ausrichtungspunkt der Diktat-Pille im Fenster (von ihrer linken
    /// Kante). Normal die Mitte; aufgeklappt per Darüberfahren der Punkt, der
    /// die rechte Kante dort hält, wo sie zugeklappt war. Begrenzt auf
    /// `available` (Breite für die Pille im Fenster): Wächst die Pille beim
    /// Darüberfahren weiter (Kontext kommt dazu), bleibt sie ganz im Fenster,
    /// statt links abgeschnitten zu werden.
    static func centerGuide(
        width: CGFloat, collapsedWidth: CGFloat?, hoverExpanded: Bool,
        available: CGFloat = OverlayFrameResolver.maxPillWidth
    ) -> CGFloat {
        guard hoverExpanded, let collapsedWidth, collapsedWidth > 0, collapsedWidth < width else {
            return width / 2
        }
        let guide = width - collapsedWidth / 2
        let half = available / 2
        // Linke Kante ≥ 0: guide ≤ half; rechte Kante ≤ available: guide ≥ width − half.
        return min(max(guide, width - half), max(half, width / 2))
    }

    /// Geschätzte Breite der Status-Pille je Zustand, für die Begrenzung auf
    /// den Bildschirm (die Ansicht selbst ist so breit wie ihr Inhalt).
    static func statusWidthEstimate(mode: NotchPanelMode) -> CGFloat {
        switch mode {
        case .compact(let chips): return 64 + CGFloat(max(0, chips)) * 44
        case .alert: return NotchGeometry.pillAlertWidth
        case .expanded: return NotchGeometry.pillExpandedWidth
        }
    }

    /// Höhe des sichtbaren Inhalts je Zustand.
    static func statusContentHeight(mode: NotchPanelMode) -> CGFloat {
        switch mode {
        case .compact, .alert: return NotchGeometry.pillHeight
        case .expanded(let rows, let sections):
            return NotchGeometry.pillHeight + NotchGeometry.listHeight(rowCount: rows, sectionCount: sections)
        }
    }

    /// Sichtbarer Rahmen der Status-Pille (ohne Schattenrand): wächst aus
    /// der Pille, waagrecht um ihre Mitte, in der unteren Hälfte nach oben.
    static func statusVisibleFrame(mode: NotchPanelMode, center: CGPoint, screen: NotchScreenInfo) -> CGRect {
        NotchPillPlacement.frame(
            size: CGSize(width: statusWidthEstimate(mode: mode), height: statusContentHeight(mode: mode)),
            growingFrom: center, on: screen)
    }

    /// Fenster der Status-Pille: feste Breite, waagrecht mittig über dem
    /// sichtbaren Rahmen, rundum Platz für den Schatten.
    static func statusPanelFrame(mode: NotchPanelMode, center: CGPoint, screen: NotchScreenInfo) -> CGRect {
        let visible = statusVisibleFrame(mode: mode, center: center, screen: screen)
        return CGRect(
            x: visible.midX - statusPanelWidth / 2, y: visible.minY - shadowMargin,
            width: statusPanelWidth, height: visible.height + 2 * shadowMargin)
    }

    /// Mittelpunkt der Pille beim Ziehen: dem Versatz folgen, aber ganz im
    /// sichtbaren Bereich bleiben (Breite der Ruhe-Pille).
    static func draggedCenter(
        from start: CGPoint, by offset: CGVector, compactWidth: CGFloat, screen: NotchScreenInfo
    ) -> CGPoint {
        let size = CGSize(width: compactWidth, height: NotchGeometry.pillHeight)
        let moved = CGRect(
            x: start.x + offset.dx - size.width / 2, y: start.y + offset.dy - size.height / 2,
            width: size.width, height: size.height)
        let clamped = NotchPillPlacement.clamp(moved, to: NotchPillPlacement.usableArea(screen))
        return CGPoint(x: clamped.midX, y: clamped.midY)
    }

    /// Kopfzeile einer aufgeklappten Status-Pille (Fensterkoordinaten, unten
    /// links): so hoch wie die Pille, innerhalb des Schattenrands.
    static func isInStatusHeader(y: CGFloat, panelHeight: CGFloat, headerAtBottom: Bool) -> Bool {
        let header = NotchGeometry.pillHeight
        if headerAtBottom {
            return y >= shadowMargin && y <= shadowMargin + header
        }
        return y <= panelHeight - shadowMargin && y >= panelHeight - shadowMargin - header
    }

    /// Fenster des Diktats an der Notch: oben bündig mit dem Bildschirm, die
    /// Pille hängt mittig unter der Aussparung. Kein Rand oben (das Band
    /// liegt in der Menüleiste), unten und seitlich der übliche Rand.
    static func notchDictationPanelFrame(screen: NotchScreenInfo, panelWidth: CGFloat) -> CGRect {
        let height = screen.safeAreaTop + PillMetrics.height + shadowMargin
        return CGRect(
            x: screen.notchCenterX - panelWidth / 2, y: screen.frame.maxY - height,
            width: panelWidth, height: height)
    }

    /// Fenster des Diktats als Pille: mittig um den Mittelpunkt der Pille.
    static func pillDictationPanelOrigin(center: CGPoint, panelSize: CGSize) -> CGPoint {
        CGPoint(x: center.x - panelSize.width / 2, y: center.y - panelSize.height / 2)
    }

    /// Mittelpunkt der Diktat-Pille aus ihrem Anker (nach dem Ziehen).
    static func center(of anchor: PillAnchor) -> CGPoint {
        CGPoint(x: (anchor.minX + anchor.maxX) / 2, y: anchor.y + PillMetrics.height / 2)
    }
}

/// Wohin ein Klick auf die ruhende Pille geht: auf den Kern startet er ein
/// Diktat (wie der Hotkey), sonst öffnet er die Statusliste.
enum UnifiedPillClickTarget: Equatable {
    case core
    case status

    static func resolve(point: CGPoint, coreFrame: CGRect?) -> UnifiedPillClickTarget {
        guard let coreFrame, coreFrame.insetBy(dx: -2, dy: -2).contains(point) else { return .status }
        return .core
    }
}

/// Wohin Menüs und Listen an der Pille aufklappen: in der oberen
/// Bildschirmhälfte nach unten, in der unteren nach oben.
enum UnifiedPillMenuDirection {
    static func opensDownward(pillFrame: CGRect, screenFrame: CGRect) -> Bool {
        pillFrame.midY >= screenFrame.midY
    }
}
