import CoreGraphics
import Foundation

/// Zustandsloser Hit-Test fürs Pane-Fokus-Routing im Grid — pur und getestet.
///
/// Hintergrund (LR-AU-016): Der `leftMouseDown`-Monitor verschob die Selektion
/// auf die Pane im Hover-Flag `hoveredGridPaneID`, ohne die Klickposition zu
/// prüfen. SwiftUI verliert `onHover(false)` bei Kontextmenü, Drag und Cmd+Tab
/// (gleiches Muster wie der Scroll-Ausfall vom 23.08.2026); das Flag blieb dann
/// auf Pane X, ein Klick ins Sidebar-Suchfeld setzte die Selektion trotzdem auf
/// X, und das Terminal riss den Tastaturfokus an sich. Jetzt entscheidet jeder
/// Klick frisch anhand der gemessenen Pane-Rechtecke.
enum GridPaneHitResolver {
    /// Pane unter dem Punkt (Koordinaten wie die Frames: SwiftUI, Ursprung oben
    /// links im benannten Fenster-Koordinatenraum). `nil` = Klick außerhalb aller Panes.
    static func pane(at point: CGPoint, frames: [UUID: CGRect]) -> UUID? {
        frames.first { $0.value.contains(point) }?.key
    }

    /// Welche Pane bekommt den Fokus? Sind (noch) keine Rechtecke gemessen,
    /// gilt wie bisher das Hover-Flag — lieber der alte Weg als ein Fokus, der
    /// nie wandert. Sind Rechtecke da, zählt nur, was unter dem Zeiger liegt.
    static func focusTarget(hovered: UUID?, point: CGPoint, frames: [UUID: CGRect]) -> UUID? {
        guard !frames.isEmpty else { return hovered }
        return pane(at: point, frames: frames)
    }

    /// AppKit-Fensterkoordinate (`locationInWindow`, Ursprung unten links) →
    /// SwiftUI-Fensterraum (Ursprung oben links, unterhalb eines oberen
    /// Safe-Area-Versatzes, den der Koordinatenraum nicht enthält).
    static func swiftUIPoint(
        locationInWindow: CGPoint,
        contentViewHeight: CGFloat,
        safeAreaTopInset: CGFloat
    ) -> CGPoint {
        CGPoint(x: locationInWindow.x, y: contentViewHeight - locationInWindow.y - safeAreaTopInset)
    }
}

/// Gemessene Pane-Rechtecke. Bewusst eine Klasse in einem nicht beobachteten
/// `@State`: Layout-Messungen dürfen keinen View-Neuaufbau auslösen.
final class GridPaneFrameCache {
    var frames: [UUID: CGRect] = [:]
}
