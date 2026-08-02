import CoreGraphics
import Foundation

/// Rechnet ein `WorkspaceLayout` in Rechtecke um — pur und deterministisch.
///
/// Gleiche Eingaben ergeben immer dieselben Rechtecke. Das ist keine
/// Nebensaechlichkeit: Weicht die Rundung zwischen zwei Durchlaeufen ab,
/// entstehen Fugen zwischen den Flaechen oder Terminals werden um ein Pixel
/// umgebrochen — beides sichtbar und beides teuer, weil jede Groessenaenderung
/// die laufenden Programme zum Neuzeichnen zwingt.
enum LayoutGeometry {

    /// Mindestgroesse einer Flaeche, in Punkten.
    ///
    /// Setzt die weiche Grenze aus Entscheidung F7 durch: Passt eine weitere
    /// Flaeche nicht mehr hinein, wird gestapelt statt geteilt. Der Nutzer wird
    /// nie blockiert, das Bild bleibt lesbar. Vorgabe entspricht rund 80×24
    /// Zeichen bei ueblicher Terminal-Schrift.
    static let defaultMinimum = CGSize(width: 480, height: 260)

    /// Berechnet fuer jede Zelle ihr Rechteck.
    ///
    /// Bei `automatic` aus der Zellenzahl und dem Seitenverhaeltnis, bei
    /// `manual` aus dem Baum.
    static func frames(
        for layout: WorkspaceLayout,
        in bounds: CGRect,
        minimum: CGSize = defaultMinimum
    ) -> [UUID: CGRect] {
        guard !layout.cells.isEmpty, bounds.width > 0, bounds.height > 0 else { return [:] }

        switch layout.arrangement {
        case .automatic:
            return automaticFrames(cells: layout.cells, in: bounds, minimum: minimum)
        case let .manual(tree):
            var result: [UUID: CGRect] = [:]
            place(tree, in: bounds, into: &result)
            return result
        }
    }

    // MARK: - Automatisch

    /// Spalten und Zeilen fuer n Zellen.
    ///
    /// Ausgelagert, weil es die meistgetestete Einzelregel ist: Sie bestimmt,
    /// wie sich das Bild bei jedem Hinzufuegen und Schliessen aendert. Das
    /// Seitenverhaeltnis geht ein, damit auf einem breiten Fenster eher
    /// nebeneinander und auf einem hohen eher untereinander angeordnet wird.
    static func automaticArrangement(cellCount: Int, aspect: CGFloat) -> (columns: Int, rows: Int) {
        guard cellCount > 1 else { return (1, 1) }
        let count = Double(cellCount)
        let ratio = Double(max(aspect, 0.1))

        // Kandidaten durchprobieren und den waehlen, dessen Flaechen dem
        // Seitenverhaeltnis des Fensters am naechsten kommen. Das ist billiger
        // als es klingt (hoechstens `cellCount` Schritte) und liefert
        // nachvollziehbare Ergebnisse ohne Sonderfaelle je Anzahl.
        var best = (columns: cellCount, rows: 1)
        var bestScore = Double.infinity

        for columns in 1...cellCount {
            let rows = Int((count / Double(columns)).rounded(.up))
            // Zellen-Seitenverhaeltnis bei dieser Aufteilung
            let cellAspect = (ratio / Double(columns)) / (1.0 / Double(rows))
            // Ideal ist ein Verhaeltnis nahe 1,6 — deutlich breiter als hoch,
            // wie ein Terminal es gerne haette.
            let deviation = abs(log(cellAspect / 1.6))
            // Leere Plaetze in der letzten Reihe kosten Punkte, damit 5 Zellen
            // nicht als 3×2 mit einem Loch enden, wenn 5×1 besser passt.
            let waste = Double(columns * rows - cellCount) * 0.15

            let score = deviation + waste
            if score < bestScore {
                bestScore = score
                best = (columns, rows)
            }
        }
        return best
    }

    private static func automaticFrames(
        cells: [WorkspaceLayout.Cell],
        in bounds: CGRect,
        minimum: CGSize
    ) -> [UUID: CGRect] {
        let aspect = bounds.width / max(bounds.height, 1)
        var (columns, rows) = automaticArrangement(cellCount: cells.count, aspect: aspect)

        // Entscheidung F7: Wuerde eine Flaeche unter die Mindestgroesse
        // rutschen, wird die Aufteilung zurueckgenommen. Die uebrigen Chats
        // landen dann als Stapel in den vorhandenen Zellen — das entscheidet
        // aber der Aufrufer; hier wird nur nicht kleiner geteilt als erlaubt.
        while columns > 1, bounds.width / CGFloat(columns) < minimum.width {
            columns -= 1
            rows = Int((Double(cells.count) / Double(columns)).rounded(.up))
        }
        while rows > 1, bounds.height / CGFloat(rows) < minimum.height {
            rows -= 1
            columns = Int((Double(cells.count) / Double(rows)).rounded(.up))
        }

        var result: [UUID: CGRect] = [:]
        for (index, cell) in cells.enumerated() {
            let row = index / columns
            guard row < rows else { break }

            // Die LETZTE Reihe ist oft nicht voll — bei drei Zellen in zwei
            // Spalten bliebe unten ein Viertel der Flaeche leer. Genau dieses
            // Loch soll der Umbau abschaffen. Deshalb teilen sich die Zellen
            // einer unvollstaendigen Reihe die volle Breite untereinander auf.
            // (Das alte Modell loeste denselben Fall mit einer Sonderregel
            // „3 = zwei oben, eines breit unten"; hier folgt es aus der
            // allgemeinen Rechnung.)
            let isLastRow = row == rows - 1
            let cellsInRow = isLastRow ? (cells.count - row * columns) : columns
            let column = index - row * columns

            let x0 = (bounds.minX + bounds.width * CGFloat(column) / CGFloat(cellsInRow)).rounded()
            let x1 = (bounds.minX + bounds.width * CGFloat(column + 1) / CGFloat(cellsInRow)).rounded()
            // Kanten berechnen und Groesse daraus ableiten — NICHT Position und
            // Groesse getrennt runden. Sonst entstehen Fugen von einem Pixel
            // zwischen benachbarten Flaechen.
            let y0 = (bounds.minY + bounds.height * CGFloat(row) / CGFloat(rows)).rounded()
            let y1 = (bounds.minY + bounds.height * CGFloat(row + 1) / CGFloat(rows)).rounded()

            result[cell.id] = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
        return result
    }

    // MARK: - Manuell

    private static func place(
        _ node: WorkspaceLayout.SplitNode,
        in rect: CGRect,
        into result: inout [UUID: CGRect]
    ) {
        switch node {
        case let .leaf(cellID):
            result[cellID] = CGRect(
                x: rect.minX.rounded(), y: rect.minY.rounded(),
                width: rect.width.rounded(), height: rect.height.rounded()
            )

        case let .split(axis, children, fractions):
            let shares = LayoutNormalizer.normalizedFractions(fractions, count: children.count)
            var offset: CGFloat = 0

            for (index, child) in children.enumerated() {
                let share = CGFloat(shares[index])
                let childRect: CGRect

                switch axis {
                case .horizontal:
                    // Kanten runden, Breite daraus ableiten — siehe oben.
                    let x0 = (rect.minX + offset).rounded()
                    let x1 = (rect.minX + offset + rect.width * share).rounded()
                    childRect = CGRect(x: x0, y: rect.minY.rounded(),
                                       width: x1 - x0, height: rect.height.rounded())
                    offset += rect.width * share

                case .vertical:
                    let y0 = (rect.minY + offset).rounded()
                    let y1 = (rect.minY + offset + rect.height * share).rounded()
                    childRect = CGRect(x: rect.minX.rounded(), y: y0,
                                       width: rect.width.rounded(), height: y1 - y0)
                    offset += rect.height * share
                }

                place(child, in: childRect, into: &result)
            }
        }
    }
}
