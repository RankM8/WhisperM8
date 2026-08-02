import Foundation

/// Uebersetzt das alte Positionsraster (`AgentGridWorkspace`) in die neue
/// Anordnung (`WorkspaceLayout`) — Schema v4 → v5.
///
/// **Die zentrale Entscheidung: der Bestand wird NICHT umgeordnet.** Die
/// automatische Anordnung ist besser, aber sie ungefragt ueber eine gewachsene
/// Einrichtung zu legen fuehlt sich wie Datenverlust an, auch wenn keiner
/// vorliegt. Deshalb wird jedes bestehende Layout als `manual` uebernommen und
/// behaelt seine Aufteilung exakt. Der Weg in die neue Bedienung ist der
/// sichtbare Schalter „automatisch anordnen" (Entscheidung F6) — fuer
/// Bestandsnutzer die einzige Tuer dorthin, deshalb darf er nicht versteckt
/// sein.
///
/// Neue Workspaces starten dagegen auf `automatic`; dort gibt es nichts zu
/// bewahren.
///
/// Die Funktion ist pur — damit laesst sie sich gegen echte Felddaten testen,
/// nicht nur gegen konstruierte.
enum WorkspaceLayoutMigration {

    static func migrate(_ workspaces: [AgentGridWorkspace]) -> [WorkspaceLayout] {
        workspaces.map(migrate)
    }

    static func migrate(_ old: AgentGridWorkspace) -> WorkspaceLayout {
        // Nur belegte Plaetze werden Zellen. Die `nil`-Slots waren nie Inhalt,
        // sondern Luecke — sie zu uebernehmen hiesse, den Konstruktionsfehler
        // mitzunehmen.
        let visible = old.slots.prefix(old.capacity)
        var cells: [WorkspaceLayout.Cell] = []
        var positions: [Int] = []          // Slot-Index je Zelle, fuer den Baum

        for (index, slot) in visible.enumerated() {
            guard let session = slot else { continue }
            cells.append(WorkspaceLayout.Cell(session: session))
            positions.append(index)
        }

        // Sessions jenseits der sichtbaren Kapazitaet gab es im alten Modell
        // nicht — falls die Datei sie doch traegt (hand-editiert, fremde
        // Version), gehen sie nicht verloren, sondern kommen hinten dazu.
        for slot in old.slots.dropFirst(old.capacity) {
            guard let session = slot else { continue }
            cells.append(WorkspaceLayout.Cell(session: session))
        }

        var layout = WorkspaceLayout(
            id: old.id,
            name: old.name,
            colorHex: old.colorHex,
            cells: cells,
            arrangement: .automatic,
            source: .manual
        )

        // Erst ab zwei Zellen ist eine Aufteilung ueberhaupt sichtbar. Bei
        // einer einzigen fuellt sie ohnehin die Flaeche — dann ist `automatic`
        // ehrlicher, weil es keine Absicht des Nutzers gibt, die zu bewahren
        // waere.
        if cells.count > 1 {
            layout.arrangement = .manual(tree(
                for: old,
                cellIDs: cells.map(\.id),
                positions: positions
            ))
        }

        return LayoutNormalizer.normalize(layout)
    }

    // MARK: - Baumaufbau

    /// Baut aus Kapazitaet und Gewichten den Baum, der dieselbe Aufteilung
    /// ergibt wie vorher.
    ///
    /// Das alte Modell war zeilenweise organisiert: `rows(forCapacity:)` mal
    /// `columns(forCapacity:)`, mit einem Sonderfall bei drei Plaetzen („zwei
    /// oben, einer breit unten"). Der Baum bildet das nach: aussen die Zeilen,
    /// innen die Spalten.
    private static func tree(
        for old: AgentGridWorkspace,
        cellIDs: [UUID],
        positions: [Int]
    ) -> WorkspaceLayout.SplitNode {
        let columns = AgentGridWorkspace.columns(forCapacity: old.capacity)
        let rows = AgentGridWorkspace.rows(forCapacity: old.capacity)

        // Slot-Index → Zell-ID. Zellen ohne Position (die Ueberzaehligen von
        // oben) haengen hinten an und bekommen eine eigene Zeile.
        var cellForSlot: [Int: UUID] = [:]
        for (offset, slot) in positions.enumerated() where offset < cellIDs.count {
            cellForSlot[slot] = cellIDs[offset]
        }
        let extraCells = cellIDs.dropFirst(positions.count)

        var rowNodes: [WorkspaceLayout.SplitNode] = []
        var rowWeights: [Double] = []

        for row in 0..<rows {
            var columnNodes: [WorkspaceLayout.SplitNode] = []
            var columnWeights: [Double] = []

            for column in 0..<columns {
                let slot = slotIndex(row: row, column: column, capacity: old.capacity,
                                     columns: columns)
                // Der Sonderfall „3 = zwei oben, einer breit unten": Slot 2
                // spannt die ganze untere Zeile, es gibt dort keine zweite
                // Spalte.
                guard let slot else { continue }
                guard let cellID = cellForSlot[slot] else { continue }
                columnNodes.append(.leaf(cellID: cellID))
                columnWeights.append(weight(old.columnFractions, at: column, count: columns))
            }

            guard !columnNodes.isEmpty else { continue }
            rowNodes.append(columnNodes.count == 1
                ? columnNodes[0]
                : .split(axis: .horizontal, children: columnNodes,
                         fractions: LayoutNormalizer.normalizedFractions(
                            columnWeights, count: columnNodes.count)))
            rowWeights.append(weight(old.rowFractions, at: row, count: rows))
        }

        for cellID in extraCells {
            rowNodes.append(.leaf(cellID: cellID))
            rowWeights.append(1.0 / Double(max(rows, 1)))
        }

        guard rowNodes.count > 1 else {
            return rowNodes.first ?? .leaf(cellID: cellIDs.first ?? UUID())
        }
        return .split(axis: .vertical, children: rowNodes,
                      fractions: LayoutNormalizer.normalizedFractions(
                        rowWeights, count: rowNodes.count))
    }

    /// Welcher Slot an dieser Gitterstelle liegt — `nil`, wenn dort keiner ist.
    ///
    /// Bildet die Geometrie des alten Modells ab: 2 = eine Zeile, 3 = zwei
    /// oben und einer ueber die volle Breite, sonst zeilenweise.
    private static func slotIndex(row: Int, column: Int, capacity: Int, columns: Int) -> Int? {
        if capacity == 3 {
            if row == 0 { return column < 2 ? column : nil }
            return column == 0 ? 2 : nil     // untere Zeile: nur Slot 2, volle Breite
        }
        let index = row * columns + column
        return index < capacity ? index : nil
    }

    private static func weight(_ fractions: [Double], at index: Int, count: Int) -> Double {
        guard index < fractions.count, fractions[index].isFinite, fractions[index] > 0 else {
            return 1.0 / Double(max(count, 1))
        }
        return fractions[index]
    }
}
