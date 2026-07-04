import AppKit

// MARK: - Pill-Anker (Persistenz-Schema)

/// Persistierter Anker der SICHTBAREN Pill in Screen-Koordinaten (bottom-left).
///
/// Es werden bewusst BEIDE Kanten gespeichert: der Resolver bevorzugt eine
/// rechts verankerte Pill (sie wächst beim Expandieren nach links, ✓/✕ bleiben
/// exakt stehen). Passt die voll expandierte Pill dort nicht mehr auf den
/// Schirm — Anker nahe der linken Bildschirmkante — wird gespiegelt und die
/// LINKE Kante wird zum Fixpunkt (Pill wächst nach rechts).
struct PillAnchor: Equatable {
    /// Rechte Kante der sichtbaren Pill.
    var maxX: CGFloat
    /// Linke Kante der sichtbaren Pill.
    var minX: CGFloat
    /// Unterkante der sichtbaren Pill.
    var y: CGFloat
}

/// Wachstumsrichtung der Pill innerhalb des (fixen) Panels.
enum PillAlignment: Equatable {
    /// Rechte Kante fix, Pill wächst nach links (Custom-Position, Mini-Default).
    case trailing
    /// Linke Kante fix, Pill wächst nach rechts (Spiegel-Fall an der linken Kante).
    case leading
    /// Mittig fix, Pill wächst symmetrisch in beide Richtungen
    /// (Full-Default: kein „links wachsen + nachrücken" mehr).
    case center
}

// MARK: - Frame-Resolver

/// Reine Geometrie der Recording-Pill — unit-getestet, keine UI-Abhängigkeiten.
///
/// Kernidee: Das NSPanel hat in ALLEN Zuständen dieselbe (Maximal-)Größe;
/// nur die SwiftUI-Pill darin animiert ihre Breite. Fenster-Frame-Animationen
/// und SwiftUI laufen nie frame-synchron — deshalb animiert ausschließlich
/// SwiftUI, das Panel steht still. Klicks auf die transparente Restfläche
/// reicht `PillHitTestHostingView` ans darunterliegende Fenster durch.
enum OverlayFrameResolver {
    /// Maximale Breite der sichtbaren Pill (voll expandiert, langer Kontext-Chip).
    static let maxPillWidth: CGFloat = 560
    /// Höhe der sichtbaren Pill — konstant in allen Zuständen.
    static let pillHeight: CGFloat = 40
    /// Rand um die Pill für den SwiftUI-Schatten. Klicks dort gehen durch.
    static let contentMargin: CGFloat = 24
    /// Abstand der Pill-Unterkante zur Unterkante des visibleFrame (Default-Position).
    static let defaultBottomOffset: CGFloat = 40

    /// Fixe Panel-Größe (Pill-Maximum + Schattenrand rundum).
    static var panelSize: NSSize {
        NSSize(
            width: maxPillWidth + contentMargin * 2,
            height: pillHeight + contentMargin * 2
        )
    }

    struct Resolution: Equatable {
        var panelOrigin: NSPoint
        var alignment: PillAlignment
    }

    /// Rechnet den persistierten Anker in Panel-Origin + Wachstumsrichtung um.
    ///
    /// Kriterium für den Spiegel-Fall ist die sichtbare Pill in VOLLER Breite —
    /// nicht das Panel: der Schattenrand darf über die Screen-Kante überstehen.
    static func resolve(anchor: PillAnchor, visibleFrame: NSRect) -> Resolution {
        let y = clampedPillMinY(anchor.y, visibleFrame: visibleFrame)
        let panelY = y - contentMargin

        // Bevorzugt: rechts verankert. Anker zunächst in den Screen holen.
        let maxX = min(max(anchor.maxX, visibleFrame.minX + pillHeight), visibleFrame.maxX)
        if maxX - maxPillWidth >= visibleFrame.minX {
            return Resolution(
                panelOrigin: NSPoint(x: maxX + contentMargin - panelSize.width, y: panelY),
                alignment: .trailing
            )
        }

        // Spiegel-Fall: links verankert, Pill wächst nach rechts.
        var minX = max(anchor.minX, visibleFrame.minX)
        // Schirm schmaler als die volle Pill oder Anker zu weit rechts:
        // linke Kante so weit zurückziehen, dass die volle Breite passt.
        minX = min(minX, max(visibleFrame.minX, visibleFrame.maxX - maxPillWidth))
        return Resolution(
            panelOrigin: NSPoint(x: minX - contentMargin, y: panelY),
            alignment: .leading
        )
    }

    /// Default-Resolution mit Center-Anker (Full-Style): Panel mittig auf dem
    /// Screen, Pill zentriert darin — SwiftUI hält sie damit von selbst in
    /// der Mitte, jede Breitenänderung wächst symmetrisch. Keine
    /// Breiten-Schätzung, keine Nachzentrierung nötig.
    static func centeredDefaultResolution(visibleFrame: NSRect) -> Resolution {
        Resolution(
            panelOrigin: NSPoint(
                x: visibleFrame.midX - panelSize.width / 2,
                y: visibleFrame.minY + defaultBottomOffset - contentMargin
            ),
            alignment: .center
        )
    }

    /// Default-Anker: Pill horizontal zentriert, unten mit Standard-Offset.
    /// `estimatedPillWidth` = erwartete Breite im Ruhezustand des aktiven Stils
    /// (der Controller re-zentriert nach dem ersten echten Layout exakt).
    static func defaultAnchor(estimatedPillWidth: CGFloat, visibleFrame: NSRect) -> PillAnchor {
        let width = min(estimatedPillWidth, maxPillWidth)
        let maxX = visibleFrame.midX + width / 2
        return PillAnchor(
            maxX: maxX,
            minX: maxX - width,
            y: visibleFrame.minY + defaultBottomOffset
        )
    }

    /// Clamp während des Drags: die SICHTBARE Pill bleibt komplett im
    /// visibleFrame, der Schattenrand des Panels darf überstehen.
    /// `pillFrameInPanel` kommt aus dem SwiftUI-Layout (AppKit-Koordinaten).
    static func clampedPanelOrigin(
        panelOrigin: NSPoint,
        pillFrameInPanel: NSRect,
        visibleFrame: NSRect
    ) -> NSPoint {
        let pill = pillFrameInPanel.offsetBy(dx: panelOrigin.x, dy: panelOrigin.y)
        var dx: CGFloat = 0
        var dy: CGFloat = 0

        if pill.width >= visibleFrame.width {
            dx = visibleFrame.minX - pill.minX
        } else if pill.minX < visibleFrame.minX {
            dx = visibleFrame.minX - pill.minX
        } else if pill.maxX > visibleFrame.maxX {
            dx = visibleFrame.maxX - pill.maxX
        }

        if pill.height >= visibleFrame.height {
            dy = visibleFrame.minY - pill.minY
        } else if pill.minY < visibleFrame.minY {
            dy = visibleFrame.minY - pill.minY
        } else if pill.maxY > visibleFrame.maxY {
            dy = visibleFrame.maxY - pill.maxY
        }

        return NSPoint(x: panelOrigin.x + dx, y: panelOrigin.y + dy)
    }

    /// Anker aus dem aktuellen Zustand (für die Persistenz am Drag-Ende).
    static func anchor(panelOrigin: NSPoint, pillFrameInPanel: NSRect) -> PillAnchor {
        PillAnchor(
            maxX: panelOrigin.x + pillFrameInPanel.maxX,
            minX: panelOrigin.x + pillFrameInPanel.minX,
            y: panelOrigin.y + pillFrameInPanel.minY
        )
    }

    /// Übersetzt die alte Origin-Persistenz (Panel-Origin der 590×56/220×46-
    /// Panels, Pill = ganzes Panel) einmalig ins Anker-Schema.
    static func migrateLegacyOrigin(_ origin: NSPoint, legacyPanelSize: NSSize) -> PillAnchor {
        PillAnchor(
            maxX: origin.x + legacyPanelSize.width,
            minX: origin.x,
            y: origin.y + max(0, (legacyPanelSize.height - pillHeight) / 2)
        )
    }

    private static func clampedPillMinY(_ y: CGFloat, visibleFrame: NSRect) -> CGFloat {
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - pillHeight)
        return min(max(y, visibleFrame.minY), maxY)
    }
}
