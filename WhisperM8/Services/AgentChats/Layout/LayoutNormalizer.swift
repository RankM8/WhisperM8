import Foundation

/// Setzt die Invarianten eines `WorkspaceLayout` durch — die EINE Stelle, durch
/// die jede Aenderung laeuft.
///
/// **Warum zentral und nicht im Setter:** Verteilte Pruefungen driften
/// auseinander; jede neue Operation muesste alle Regeln erneut kennen. Hier ist
/// die Regel einmal formuliert, und jede Engine-Operation endet mit
/// `normalize`. Ein kaputter Zustand hinein, ein gueltiger heraus.
///
/// Die Funktion ist pur — kein Store, kein SwiftUI, keine Nebenwirkung. Damit
/// ist jede Invariante testbar, indem man sie absichtlich verletzt.
///
/// Invarianten (Plan: `docs/plans/workspace-umbau/01-datenmodell/`):
/// 1. Jede Zelle hat mindestens einen Chat — leere verschwinden
/// 2. `active` ist in `sessions` enthalten
/// 3. Ein Chat liegt in hoechstens einer Zelle DESSELBEN Layouts
/// 4. Bei `manual`: Blaetter und Zellen stimmen genau ueberein
/// 5. `fractions`: positiv, endlich, Summe 1, so viele wie Kinder
/// 6. Bei `source: .project`: `hidden` enthaelt keine Mitglieder mehr
enum LayoutNormalizer {
    static func normalize(_ layout: WorkspaceLayout) -> WorkspaceLayout {
        var result = layout

        result.cells = normalizedCells(result.cells)
        result.arrangement = normalizedArrangement(result.arrangement, cells: result.cells)
        result.bindings = normalizedBindings(result.bindings, cells: result.cells)
        result.hidden = normalizedHidden(result.hidden, cells: result.cells, source: result.source)

        return result
    }

    // MARK: - Zellen

    /// Invarianten 1–3.
    private static func normalizedCells(_ cells: [WorkspaceLayout.Cell]) -> [WorkspaceLayout.Cell] {
        var seenSessions: Set<UUID> = []
        var seenCellIDs: Set<UUID> = []
        var result: [WorkspaceLayout.Cell] = []

        for cell in cells {
            // Invariante 3: Ein Chat darf im selben Layout nur einmal
            // vorkommen. Zwei Ansichten desselben Terminals nebeneinander
            // machen die Fokus-Verwaltung mehrdeutig. UEBER Layouts hinweg ist
            // Mehrfach-Mitgliedschaft dagegen ausdruecklich erlaubt (E8) —
            // deshalb prueft das hier nur innerhalb eines Layouts.
            let unique = cell.sessions.filter { seenSessions.insert($0).inserted }

            // Invariante 1: Leere Zellen gibt es nicht. Sie waeren genau das
            // Loch, das im alten Modell zurueckblieb.
            guard let first = unique.first else { continue }

            // Doppelte Zell-IDs koennen durch fehlerhafte Migration oder
            // gleichzeitige Aenderungen entstehen; eine neue ID ist harmloser
            // als ein Baum, der zwei Zellen nicht auseinanderhalten kann.
            var cellID = cell.id
            if !seenCellIDs.insert(cellID).inserted {
                cellID = UUID()
                seenCellIDs.insert(cellID)
            }

            // Invariante 2: `active` muss in `sessions` liegen — sonst zeigt
            // die Zelle auf einen Chat, den sie nicht hat, und die Flaeche
            // bliebe ohne Erklaerung leer.
            let active = unique.contains(cell.active) ? cell.active : first

            result.append(WorkspaceLayout.Cell(id: cellID, sessions: unique, active: active))
        }

        return result
    }

    // MARK: - Anordnung

    /// Invarianten 4–5.
    private static func normalizedArrangement(
        _ arrangement: WorkspaceLayout.Arrangement,
        cells: [WorkspaceLayout.Cell]
    ) -> WorkspaceLayout.Arrangement {
        guard case let .manual(tree) = arrangement else { return .automatic }

        let validIDs = Set(cells.map(\.id))
        guard let pruned = prune(tree, validIDs: validIDs) else {
            // Kein Blatt hat ueberlebt — der Baum ist wertlos. Zurueck auf
            // automatisch, statt eine leere Flaeche zu zeichnen.
            return .automatic
        }

        // Invariante 4, zweite Haelfte: Zellen, die im Baum fehlen, waeren
        // unsichtbar, obwohl sie Mitglied sind. Sie werden hinten angehaengt.
        let covered = Set(pruned.leafIDs)
        let missing = cells.map(\.id).filter { !covered.contains($0) }
        guard !missing.isEmpty else { return .manual(pruned) }

        let appended = missing.map { WorkspaceLayout.SplitNode.leaf(cellID: $0) }
        let children = [pruned] + appended
        return .manual(.split(
            axis: .horizontal,
            children: children,
            fractions: equalFractions(count: children.count)
        ))
    }

    /// Entfernt Blaetter ohne Zelle und zieht dabei entstehende Einzelkinder
    /// hoch. Gibt `nil` zurueck, wenn nichts uebrig bleibt.
    private static func prune(
        _ node: WorkspaceLayout.SplitNode,
        validIDs: Set<UUID>
    ) -> WorkspaceLayout.SplitNode? {
        switch node {
        case let .leaf(cellID):
            return validIDs.contains(cellID) ? node : nil

        case let .split(axis, children, fractions):
            var keptChildren: [WorkspaceLayout.SplitNode] = []
            var keptFractions: [Double] = []

            for (index, child) in children.enumerated() {
                guard let kept = prune(child, validIDs: validIDs) else { continue }
                keptChildren.append(kept)
                // Anteil des entfallenen Kindes verfaellt; die Summe wird
                // unten neu auf 1 gebracht. Die Verhaeltnisse der uebrigen
                // bleiben dabei erhalten.
                keptFractions.append(index < fractions.count ? fractions[index] : 0)
            }

            switch keptChildren.count {
            case 0: return nil
            case 1: return keptChildren[0]   // Einzelkind hochziehen
            default:
                return .split(
                    axis: axis,
                    children: keptChildren,
                    fractions: normalizedFractions(keptFractions, count: keptChildren.count)
                )
            }
        }
    }

    /// Invariante 5: positiv, endlich, Summe 1, so viele wie Kinder.
    /// Flaechen mit Breite 0 oder `NaN` sind im alten Modell schon einmal
    /// aufgetreten — deshalb wird hier nicht vertraut, sondern gerechnet.
    static func normalizedFractions(_ fractions: [Double], count: Int) -> [Double] {
        guard count > 0 else { return [] }
        let usable = fractions.prefix(count).map { value -> Double in
            value.isFinite && value > 0 ? value : 0
        }
        var padded = Array(usable)
        if padded.count < count {
            padded.append(contentsOf: Array(repeating: 0, count: count - padded.count))
        }
        let sum = padded.reduce(0, +)
        guard sum > 0 else { return equalFractions(count: count) }
        return padded.map { $0 / sum }
    }

    static func equalFractions(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        return Array(repeating: 1.0 / Double(count), count: count)
    }

    // MARK: - Bindungen und Ausgeblendete

    /// Bindungen auf Chats, die es nicht mehr gibt, sind wertlos — sie wuerden
    /// eine Stapelung erzwingen, die niemand mehr sieht.
    private static func normalizedBindings(
        _ bindings: [UUID: UUID],
        cells: [WorkspaceLayout.Cell]
    ) -> [UUID: UUID] {
        let present = Set(cells.flatMap(\.sessions))
        return bindings.filter { present.contains($0.key) && present.contains($0.value) }
    }

    /// Invariante 6: Ein Chat kann nicht gleichzeitig Mitglied und
    /// ausgeblendet sein. Bei eigenen Layouts gibt es `hidden` gar nicht.
    private static func normalizedHidden(
        _ hidden: [UUID],
        cells: [WorkspaceLayout.Cell],
        source: WorkspaceLayout.Source
    ) -> [UUID] {
        guard source.isDerived else { return [] }
        let present = Set(cells.flatMap(\.sessions))
        var seen: Set<UUID> = []
        return hidden.filter { !present.contains($0) && seen.insert($0).inserted }
    }
}
