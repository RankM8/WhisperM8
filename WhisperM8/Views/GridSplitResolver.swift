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

    // MARK: - Mehrspurige Achsen (Kapazitäten 6/9, Plan F10)

    /// Punktgrößen aller Spuren einer Achse aus dem Gewichts-Vektor
    /// (Summe 1, siehe `AgentGridWorkspace.normalizedFractions`). Die letzte
    /// Spur nimmt den Rundungsrest — die Summe passt exakt in `total`.
    /// Jede Spur wird auf `minPane` geclampt, solange die Fläche das
    /// hergibt (Review-Finding: gespeicherte kleine Gewichte quetschten
    /// Panes beim Fenster-Verkleinern unter die Mindestgröße, der erste
    /// Drag-Tick sprang dann zur Clamp-Grenze); reicht die Fläche nicht
    /// für alle Mindest-Panes, quetschen sich alle gleichmäßig.
    static func trackSizes(total: CGFloat, fractions: [Double]) -> [CGFloat] {
        guard !fractions.isEmpty else { return [] }
        let count = fractions.count
        let usable = max(0, total - divider * CGFloat(count - 1))
        let clamped = clampedTrackFractions(fractions, usable: usable)
        var sizes = clamped.map { (usable * CGFloat($0)).rounded() }
        let assigned = sizes.dropLast().reduce(0, +)
        sizes[sizes.count - 1] = max(0, usable - assigned)
        return sizes
    }

    /// Projiziert Gewichte auf den zulässigen Bereich (jede Spur ≥
    /// `minPane/usable`): Defizite der Unter-Minimum-Spuren werden
    /// proportional von den übrigen abgezogen. Zu kleine Gesamtfläche →
    /// Gleichverteilung (alle quetschen sich gleichmäßig, wie beim
    /// 2er-Split).
    static func clampedTrackFractions(_ fractions: [Double], usable: CGFloat) -> [Double] {
        let count = fractions.count
        guard count > 1 else { return fractions }
        guard usable > minPane * CGFloat(count) else {
            return Array(repeating: 1.0 / Double(count), count: count)
        }
        let minFraction = Double(minPane / usable)
        var result = fractions
        // Iterativ (max. count Runden): Clampen kann weitere Spuren unter
        // das Minimum drücken.
        for _ in 0 ..< count {
            let deficits = result.map { max(0, minFraction - $0) }
            let totalDeficit = deficits.reduce(0, +)
            if totalDeficit <= 0.0001 { break }
            let donors = result.enumerated().filter { $0.element > minFraction }
            let donorSurplus = donors.reduce(0.0) { $0 + ($1.element - minFraction) }
            guard donorSurplus > 0 else { break }
            for index in result.indices {
                if result[index] < minFraction {
                    result[index] = minFraction
                } else if result[index] > minFraction {
                    let share = (result[index] - minFraction) / donorSurplus
                    result[index] -= totalDeficit * share
                }
            }
        }
        return result
    }

    /// Gewichte während eines Drags des Dividers `dividerIndex` (zwischen
    /// Spur i und i+1): verschiebt Anteil NUR zwischen den beiden Nachbarn
    /// (alle übrigen Spuren bleiben exakt), geclampt auf `minPane` je Seite.
    /// Ist das Nachbar-Paar zu klein für zwei Mindest-Panes, bleibt der
    /// Basis-Vektor unverändert.
    static func fractionsDuringDrag(
        base: [Double],
        dividerIndex: Int,
        translation: CGFloat,
        total: CGFloat
    ) -> [Double] {
        guard base.indices.contains(dividerIndex),
              base.indices.contains(dividerIndex + 1) else { return base }
        let usable = max(1, total - divider * CGFloat(base.count - 1))
        let combined = base[dividerIndex] + base[dividerIndex + 1]
        let combinedPoints = usable * CGFloat(combined)
        guard combinedPoints > minPane * 2 else { return base }

        let currentFirst = usable * CGFloat(base[dividerIndex])
        let newFirst = min(max(currentFirst + translation, minPane), combinedPoints - minPane)
        var next = base
        next[dividerIndex] = Double(newFirst / usable)
        next[dividerIndex + 1] = combined - next[dividerIndex]
        return next
    }
}
