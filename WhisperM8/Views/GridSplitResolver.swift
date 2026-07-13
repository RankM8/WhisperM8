import CoreGraphics
import Foundation

/// Split-Verhältnisse der Grid-Trennlinien — pro Achse EIN Verhältnis
/// (Spaltenbreite, Zeilenhöhe), damit das Grid ein sauberes Raster bleibt.
/// Pure Logik nach dem Muster `SidebarWidthResolver`; unit-getestet in
/// `GridSplitResolverTests`. Gespeichert wird der Wunschwert global via
/// `@AppStorage` (Konvention der Sidebar-Breite), angewendet wird immer
/// der geclampte Wert gegen die aktuelle Fläche.
enum GridSplitResolver {
    /// Default und Doppelklick-Reset: hälftig.
    static let defaultFraction: Double = 0.5
    /// Mindestgröße einer Pane in Punkten — kein zerquetschtes Terminal.
    static let minPane: CGFloat = 240
    /// Breite der Trennlinie (der 1-px-„Gap" des Grids).
    static let divider: CGFloat = 1

    /// Erlaubter Verhältnis-Bereich für die aktuelle Gesamtgröße. Ist die
    /// Fläche zu klein für zwei Mindest-Panes, gewinnt hälftig — beide
    /// quetschen sich gleichmäßig (gleiches Verhalten wie das Fenster
    /// selbst, das bewusst keine Mindestgröße hat).
    static func clampedFraction(_ fraction: Double, total: CGFloat) -> Double {
        let usable = total - divider
        guard usable > minPane * 2 else { return defaultFraction }
        let minFraction = Double(minPane / usable)
        return min(max(fraction, minFraction), 1 - minFraction)
    }

    /// Punktgröße der ERSTEN Pane (links bzw. oben) für ein gespeichertes
    /// Verhältnis.
    static func firstSize(total: CGFloat, fraction: Double) -> CGFloat {
        let usable = max(0, total - divider)
        return (usable * CGFloat(clampedFraction(fraction, total: total))).rounded()
    }

    /// Verhältnis während eines aktiven Drags: Startgröße der ersten Pane
    /// plus kumulative Translation, live geclampt — der Griff „klebt" an
    /// den Grenzen.
    static func fractionDuringDrag(
        startFirstSize: CGFloat,
        translation: CGFloat,
        total: CGFloat
    ) -> Double {
        let usable = max(1, total - divider)
        return clampedFraction(Double((startFirstSize + translation) / usable), total: total)
    }
}
