import Foundation

/// Pure Breiten-Logik fuer die per Drag anpassbare Agent-Chats-Sidebar.
/// Window-frei → unit-testbar (Konvention wie `TabSelectionResolver`).
///
/// Persistiert wird der "Wunschwert" des Users; ANGEWENDET wird immer
/// `effectiveWidth`, das gegen die aktuelle Fenstergeometrie clampt. Dadurch
/// brauchen Resize/Fullscreen/kleine Fenster/Relaunch kein Event-Handling —
/// jedes Layout rechnet den gueltigen Wert frisch, ein alter grosser Wert
/// kann ein kleines Fenster nie kaputt layouten.
enum SidebarWidthResolver {
    /// Bisherige Festbreite = Untergrenze: die Sidebar bleibt mindestens so
    /// breit wie vor dem Resize-Feature.
    static let minWidth: CGFloat = 276
    /// Doppelklick aufs Handle setzt hierauf zurueck.
    static let defaultWidth: CGFloat = minWidth
    /// Mindest-Restbreite fuer den Content (Tab-Strip + brauchbares Terminal).
    static let contentMinWidth: CGFloat = 480
    /// Absolute Obergrenze: die Sidebar nimmt nie mehr als die halbe App ein.
    static let windowFractionCap: CGFloat = 0.5

    /// Dynamische Obergrenze fuer die aktuelle Fenstergeometrie: es muss
    /// `contentMinWidth` (+ Inspector, falls sichtbar) uebrig bleiben, und
    /// mehr als die halbe Fensterbreite gibt es nie. Faellt das Fenster unter
    /// Sidebar+Content-Mindestmass, gewinnt `minWidth` — die Sidebar
    /// schrumpft nie unter ihr altes Festmass (gleiches Quetsch-Verhalten
    /// wie vor dem Feature; das Fenster hat bewusst keine Mindestgroesse).
    static func maxWidth(windowWidth: CGFloat, inspectorWidth: CGFloat) -> CGFloat {
        let byContent = windowWidth - contentMinWidth - inspectorWidth
        let byFraction = windowWidth * windowFractionCap
        return max(minWidth, min(byContent, byFraction))
    }

    /// Der tatsaechlich zu layoutende Wert: gespeicherter Wunschwert, gegen
    /// `[minWidth, maxWidth]` geclampt.
    static func effectiveWidth(stored: CGFloat, windowWidth: CGFloat, inspectorWidth: CGFloat) -> CGFloat {
        let upper = maxWidth(windowWidth: windowWidth, inspectorWidth: inspectorWidth)
        return min(max(stored, minWidth), upper)
    }

    /// Breite waehrend eines aktiven Drags: Startbreite + horizontale
    /// Translation, live geclampt — das Handle "klebt" an den Grenzen.
    static func widthDuringDrag(
        startWidth: CGFloat,
        translation: CGFloat,
        windowWidth: CGFloat,
        inspectorWidth: CGFloat
    ) -> CGFloat {
        effectiveWidth(
            stored: startWidth + translation,
            windowWidth: windowWidth,
            inspectorWidth: inspectorWidth
        )
    }
}
