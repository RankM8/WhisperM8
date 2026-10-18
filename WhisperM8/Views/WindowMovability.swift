import CoreGraphics
import Foundation

/// Zustandslose Entscheidung, ob das Fenster per Titelband verschiebbar sein
/// darf — pur und getestet.
///
/// Hintergrund (LR-AU-008): `window.isMovable` hing allein an Hover-Flags
/// (Tab-Strip, Sidebar-/Inspector-Resize-Rand). Verschwindet der Rand unter dem
/// Zeiger (Sidebar per Kürzel ausgeblendet), öffnet sich ein Kontextmenü oder
/// wechselt der Nutzer per Cmd+Tab, kommt `onHover(false)` nie an — `isMovable`
/// blieb `false`, das Fenster ließ sich nicht mehr am Titelband ziehen. Jetzt
/// wird das Flag vor jedem Linksklick frisch aus der Zeigerposition berechnet.
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

    /// `false` über dem Tab-Strip (Tab-Drag/Reorder) und über einem Resize-Rand,
    /// sonst `true`. Kennt keinen Zustand — jedes Event entscheidet frisch.
    static func isMovable(
        pointInWindow: CGPoint,
        contentViewHeight: CGFloat,
        stripFrame: CGRect,
        resizeHandleRanges: [ClosedRange<CGFloat>]
    ) -> Bool {
        if TabStripBand.contains(pointInWindow, contentViewHeight: contentViewHeight, stripFrame: stripFrame) {
            return false
        }
        if resizeHandleRanges.contains(where: { $0.contains(pointInWindow.x) }) {
            return false
        }
        return true
    }
}
