import CoreGraphics
import Foundation

/// Ausgewiesene Grifffläche im Titelband: hier darf ein Drag das Fenster
/// verschieben. X-Spanne in Fensterkoordinaten (links = 0), `depth` ist die
/// Höhe ab Fensteroberkante. Bewusst kein gemessenes Y — die SwiftUI-Y-
/// Umrechnung war im Fenstermodus schon einmal fragil (siehe `TabStripBand`).
struct WindowDragArea: Equatable {
    var xRange: ClosedRange<CGFloat>
    var depth: CGFloat
}

/// Zustandslose Entscheidung, ob das Fenster per Titelband verschiebbar sein
/// darf — pur und getestet.
///
/// Hintergrund (LR-AU-008): `window.isMovable` hing allein an Hover-Flags
/// (Tab-Strip, Sidebar-/Inspector-Resize-Rand). Verschwindet der Rand unter dem
/// Zeiger (Sidebar per Kürzel ausgeblendet), öffnet sich ein Kontextmenü oder
/// wechselt der Nutzer per Cmd+Tab, kommt `onHover(false)` nie an — `isMovable`
/// blieb `false`, das Fenster ließ sich nicht mehr am Titelband ziehen.
///
/// Zweiter Befund (10.11.2026): Geschützt war nur der Tab-Strip. Alle anderen
/// Knöpfe im Titelband (Sidebar, Tab-Gruppen, Plus, Projektkontext,
/// Ressourcen-Anzeige) lagen auf verschiebbarer Fläche — ein Klick mit einem
/// Pixel Mausbewegung zog das Fenster, statt den Knopf auszulösen. Deshalb
/// gilt im Titelband jetzt die Umkehrung: verschiebbar ist nur, was als
/// Grifffläche ausgewiesen ist. Ein neuer Knopf ist damit von selbst sicher.
enum WindowMovability {
    /// Halbe Breite der unsichtbaren Resize-Zone (9 pt, je 4,5 pt je Seite).
    static let resizeHandleHalfWidth: CGFloat = 4.5

    /// X-Spannen der Resize-Zonen (Fensterkoordinaten, links = 0).
    static func resizeHandleRanges(
        sidebarWidth: CGFloat?,
        inspectorWidth: CGFloat?,
        windowWidth: CGFloat
    ) -> [ClosedRange<CGFloat>] {
        var ranges: [ClosedRange<CGFloat>] = []
        if let sidebarWidth {
            ranges.append((sidebarWidth - resizeHandleHalfWidth)...(sidebarWidth + resizeHandleHalfWidth))
        }
        if let inspectorWidth {
            let edge = windowWidth - inspectorWidth
            ranges.append((edge - resizeHandleHalfWidth)...(edge + resizeHandleHalfWidth))
        }
        return ranges
    }

    /// Liegt der Punkt (AppKit-Fensterkoordinaten, Ursprung unten links) auf
    /// einer Grifffläche?
    static func isOverDragArea(
        pointInWindow: CGPoint,
        contentViewHeight: CGFloat,
        dragAreas: [WindowDragArea]
    ) -> Bool {
        let depth = contentViewHeight - pointInWindow.y
        return dragAreas.contains { $0.xRange.contains(pointInWindow.x) && depth <= $0.depth }
    }

    /// `false` über dem Tab-Strip (Tab-Drag/Reorder) und über einem Resize-Rand.
    /// Im Titelband sonst nur auf einer Grifffläche `true`. Kennt keinen
    /// Zustand — jedes Event entscheidet frisch.
    ///
    /// Ohne gemessene Griffflächen (vor dem ersten Layout) gilt das frühere
    /// Verhalten: alles außer Strip und Rändern ist verschiebbar. So kann ein
    /// Messfehler das Fenster nie unverschiebbar machen.
    static func isMovable(
        pointInWindow: CGPoint,
        contentViewHeight: CGFloat,
        stripFrame: CGRect,
        resizeHandleRanges: [ClosedRange<CGFloat>],
        dragAreas: [WindowDragArea] = []
    ) -> Bool {
        if TabStripBand.contains(pointInWindow, contentViewHeight: contentViewHeight, stripFrame: stripFrame) {
            return false
        }
        if resizeHandleRanges.contains(where: { $0.contains(pointInWindow.x) }) {
            return false
        }
        // Unterhalb des Titelbands zieht macOS ohnehin nicht.
        guard pointInWindow.y >= contentViewHeight - TabStripBand.height else { return true }
        guard !dragAreas.isEmpty else { return true }
        return isOverDragArea(pointInWindow: pointInWindow, contentViewHeight: contentViewHeight, dragAreas: dragAreas)
    }
}
