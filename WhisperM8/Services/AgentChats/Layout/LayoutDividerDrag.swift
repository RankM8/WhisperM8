import CoreGraphics
import Foundation

/// Das Ziehen eines Trenners — mit der Dehn-Technik.
///
/// **Warum nicht einfach die Groessen laufend anpassen:** Gemessen am
/// 02.08.2026 kostet eine Groessenaenderung bei neun Flaechen 11,24 ms allein
/// auf der Terminal-Seite. Dazu kommt, dass jedes laufende Programm die neue
/// Zeichenzahl per SIGWINCH erfaehrt und sein Bild komplett neu aufbaut — ein
/// Bildschirm Ausgabe kostet nochmal 1,40 ms je Flaeche. Zusammen rund 24 ms,
/// waehrend ein Bild bei 60 Hz nur 16,7 ms hat.
///
/// Deshalb: **Waehrend des Ziehens wird nur gedehnt.** Die Ansicht streckt die
/// vorhandenen Flaechen, die Terminals merken nichts. Erst beim Loslassen
/// bekommen sie ihre neue Groesse — einmal statt dreissigmal pro Sekunde.
///
/// Das laesst sich nicht nachruesten: Die gesamte Geometrie-Kette haengt daran,
/// ob eine Groesse vorlaeufig oder endgueltig ist.
struct LayoutDividerDrag: Equatable {

    /// Ein Trenner zwischen zwei benachbarten Flaechen eines Splits.
    struct Divider: Equatable {
        /// Die Kinder links/oben und rechts/unten davon.
        let leadingCellID: UUID
        let trailingCellID: UUID
        let axis: WorkspaceLayout.Axis
    }

    private(set) var divider: Divider?
    private(set) var origin: CGFloat = 0
    /// Verschiebung in Punkten seit dem Anfassen — das ist alles, was die
    /// Ansicht zum Dehnen braucht.
    private(set) var offset: CGFloat = 0

    var isActive: Bool { divider != nil }

    mutating func begin(_ divider: Divider, at position: CGFloat) {
        self.divider = divider
        self.origin = position
        self.offset = 0
    }

    /// Bewegung melden. Aendert NUR den Versatz — kein Layout, keine Terminals.
    ///
    /// `bounds` begrenzt die Verschiebung, damit eine Flaeche nicht unter die
    /// Mindestgroesse rutscht oder gar negativ wird.
    mutating func move(to position: CGFloat, limits: ClosedRange<CGFloat>) {
        guard isActive else { return }
        offset = min(max(position - origin, limits.lowerBound), limits.upperBound)
    }

    /// Beendet den Zug und liefert die neuen Anteile fuer den Split.
    ///
    /// `available` ist die Laenge der geteilten Achse in Punkten,
    /// `fractions` die bisherigen Anteile, `index` das Kind links/oben vom
    /// Trenner.
    static func resolvedFractions(
        fractions: [Double],
        index: Int,
        offset: CGFloat,
        available: CGFloat,
        minimumFraction: Double = 0.08
    ) -> [Double] {
        guard index >= 0, index + 1 < fractions.count, available > 0 else { return fractions }

        // Nur die beiden Nachbarn des Trenners aendern sich — alle anderen
        // Flaechen bleiben, wo sie sind. Sonst wanderte beim Ziehen eines
        // Trenners das halbe Layout.
        let delta = Double(offset / available)
        var result = fractions
        let vorher = (result[index], result[index + 1])
        let summe = vorher.0 + vorher.1

        result[index] = min(max(vorher.0 + delta, minimumFraction), summe - minimumFraction)
        result[index + 1] = summe - result[index]

        return LayoutNormalizer.normalizedFractions(result, count: result.count)
    }

    mutating func end() -> (divider: Divider, offset: CGFloat)? {
        defer { divider = nil; offset = 0 }
        guard let divider, offset != 0 else { return nil }
        return (divider, offset)
    }

    mutating func cancel() {
        divider = nil
        offset = 0
    }
}
