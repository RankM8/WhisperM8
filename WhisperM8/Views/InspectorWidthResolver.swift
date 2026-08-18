import Foundation

/// Pure Breiten-Logik für das per Drag anpassbare rechte Projekt-Panel —
/// Spiegelbild von `SidebarWidthResolver` (dort: linke Sidebar). Persistiert
/// wird der Wunschwert; angewendet wird immer der frisch gegen die
/// Fenstergeometrie geclampte Wert.
enum InspectorWidthResolver {
    /// Bisherige Festbreite = Default; Untergrenze knapp darunter, damit der
    /// Changes-Baum lesbar bleibt.
    static let minWidth: CGFloat = 260
    static let defaultWidth: CGFloat = 292
    /// Mindest-Restbreite für den Content (identisch zur Sidebar-Regel).
    static let contentMinWidth: CGFloat = 480
    /// Das Panel nimmt nie mehr als die halbe Fensterbreite ein.
    static let windowFractionCap: CGFloat = 0.5

    static func maxWidth(windowWidth: CGFloat, sidebarWidth: CGFloat) -> CGFloat {
        let byContent = windowWidth - contentMinWidth - sidebarWidth
        let byFraction = windowWidth * windowFractionCap
        return max(minWidth, min(byContent, byFraction))
    }

    static func effectiveWidth(stored: CGFloat, windowWidth: CGFloat, sidebarWidth: CGFloat) -> CGFloat {
        let upper = maxWidth(windowWidth: windowWidth, sidebarWidth: sidebarWidth)
        return min(max(stored, minWidth), upper)
    }

    /// Breite während eines aktiven Drags. Das Handle sitzt LINKS am Panel:
    /// Drag nach links (negative Translation) macht das Panel BREITER —
    /// deshalb geht die Translation negiert ein.
    static func widthDuringDrag(
        startWidth: CGFloat,
        translation: CGFloat,
        windowWidth: CGFloat,
        sidebarWidth: CGFloat
    ) -> CGFloat {
        effectiveWidth(
            stored: startWidth - translation,
            windowWidth: windowWidth,
            sidebarWidth: sidebarWidth
        )
    }
}
