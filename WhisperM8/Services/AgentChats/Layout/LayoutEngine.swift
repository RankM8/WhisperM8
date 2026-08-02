import Foundation

/// Die Operationen auf einem `WorkspaceLayout` — pur, ohne SwiftUI, ohne Store.
///
/// Jede Funktion nimmt ein Layout und gibt ein neues zurueck; jede endet mit
/// `LayoutNormalizer.normalize`. Damit gilt: **Was die Engine liefert, ist
/// immer gueltig** — Aufrufer muessen keine Invarianten kennen.
///
/// Vorlage ist der HTML-Zwilling (`docs/design/agent-chats-layout-engine.html`),
/// wo dieselben Operationen als JavaScript mit echter Maus erprobt wurden:
/// `reflowAuto`, `swapCells`, `replaceInCell`, `dropSession`, `throwIn`.
enum LayoutEngine {

    /// Wohin ein gezogener Chat in einer Zelle landet.
    enum DropMode {
        /// Aeusserer Ring: ersetzt den Inhalt der Zelle.
        case replace
        /// Innerer Kern: legt sich auf den Stapel.
        case stack
    }

    /// An welcher Kante einer Zelle eingefuegt wird.
    enum Edge {
        case leading, trailing, top, bottom

        var axis: WorkspaceLayout.Axis {
            switch self {
            case .leading, .trailing: return .horizontal
            case .top, .bottom: return .vertical
            }
        }

        /// `true`, wenn der neue Nachbar VOR der bestehenden Zelle liegt.
        var insertsBefore: Bool {
            switch self {
            case .leading, .top: return true
            case .trailing, .bottom: return false
            }
        }
    }

    // MARK: - Mitgliedschaft

    /// Fuegt einen Chat hinzu.
    ///
    /// Bei `automatic` bekommt er eine eigene Zelle und die Engine ordnet neu
    /// an. Bei `manual` wuerde eine neue Zelle den Baum des Nutzers sprengen —
    /// deshalb landet er dort auf dem Stapel der fokussierten Zelle. Das ist
    /// kein Notbehelf, sondern die Regel aus dem Plan: Automatik darf
    /// Unentschiedenes ordnen, aber nie Entschiedenes ueberschreiben.
    static func add(
        _ session: UUID,
        to layout: WorkspaceLayout,
        focused: UUID? = nil
    ) -> WorkspaceLayout {
        guard layout.cell(containing: session) == nil else { return layout }
        var result = layout

        if result.arrangement.isAutomatic || result.cells.isEmpty {
            result.cells.append(WorkspaceLayout.Cell(session: session))
        } else {
            let targetIndex = focused
                .flatMap { focus in result.cells.firstIndex { $0.sessions.contains(focus) } }
                ?? result.cells.indices.last!
            result.cells[targetIndex].sessions.append(session)
            result.cells[targetIndex].active = session
            // Bewusst gestapelt → als Absicht merken, damit ein spaeteres
            // Verdichten die Gruppierung nicht zerreisst.
            if let anchor = result.cells[targetIndex].sessions.first, anchor != session {
                result.bindings[session] = anchor
            }
        }

        // Bei abgeleiteten Layouts hebt das Hinzufuegen ein Ausblenden auf.
        result.hidden.removeAll { $0 == session }
        return LayoutNormalizer.normalize(result)
    }

    /// Nimmt einen Chat aus DIESEM Layout (Entscheidung E10: das × am Tab).
    ///
    /// Der Chat laeuft weiter und bleibt in der Seitenleiste — nur seine
    /// Mitgliedschaft endet. Wird die Zelle dadurch leer, verschwindet sie und
    /// die Flaeche verdichtet sich; genau das war mit „muss ich klein machen"
    /// gemeint.
    ///
    /// Bei abgeleiteten Layouts (Projekt-Workspaces) waere echtes Entfernen
    /// sinnlos — die Mitgliedschaft folgt dem Projekt und käme beim naechsten
    /// Abgleich zurueck. Dort wird stattdessen ausgeblendet.
    static func remove(_ session: UUID, from layout: WorkspaceLayout) -> WorkspaceLayout {
        var result = layout
        result.cells = result.cells.map { cell in
            var cell = cell
            cell.sessions.removeAll { $0 == session }
            return cell
        }
        result.bindings.removeValue(forKey: session)
        result.bindings = result.bindings.filter { $0.value != session }

        if result.source.isDerived, layout.cell(containing: session) != nil {
            result.hidden.append(session)
        }
        return LayoutNormalizer.normalize(result)
    }

    /// Entfernt einen beendeten Chat aus ALLEN Layouts.
    ///
    /// Zwingende Folge aus E8: Solange ein Chat in mehreren Workspaces liegen
    /// darf, muss sein Ende ueberall ankommen — sonst bleibt eine Leiche in
    /// einem Workspace zurueck, den man gerade nicht ansieht. Wird zentral beim
    /// Sessionende gerufen, nicht pro Ansicht.
    static func purge(_ session: UUID, from layouts: [WorkspaceLayout]) -> [WorkspaceLayout] {
        layouts.map { layout in
            var result = layout
            result.cells = result.cells.map { cell in
                var cell = cell
                cell.sessions.removeAll { $0 == session }
                return cell
            }
            result.bindings.removeValue(forKey: session)
            result.bindings = result.bindings.filter { $0.value != session }
            // Auch aus `hidden`: Der Chat existiert nicht mehr, ihn weiter als
            // „ausgeblendet" zu fuehren waere eine zweite Leiche.
            result.hidden.removeAll { $0 == session }
            return LayoutNormalizer.normalize(result)
        }
    }

    // MARK: - Anordnen

    /// Tauscht die Plaetze zweier Zellen.
    ///
    /// Bei `automatic` heisst das: Reihenfolge in `cells` tauschen — die
    /// Geometrie folgt daraus. Bei `manual` bleibt der Baum unveraendert und
    /// nur die Blaetter tauschen, damit die eingestellten Groessen an ihrem
    /// Platz bleiben.
    static func swap(_ a: UUID, _ b: UUID, in layout: WorkspaceLayout) -> WorkspaceLayout {
        guard a != b,
              let indexA = layout.cells.firstIndex(where: { $0.id == a }),
              let indexB = layout.cells.firstIndex(where: { $0.id == b })
        else { return layout }

        var result = layout
        result.cells.swapAt(indexA, indexB)

        if case let .manual(tree) = result.arrangement {
            result.arrangement = .manual(swapLeaves(tree, a, b))
        }
        return LayoutNormalizer.normalize(result)
    }

    private static func swapLeaves(
        _ node: WorkspaceLayout.SplitNode,
        _ a: UUID,
        _ b: UUID
    ) -> WorkspaceLayout.SplitNode {
        switch node {
        case let .leaf(cellID):
            if cellID == a { return .leaf(cellID: b) }
            if cellID == b { return .leaf(cellID: a) }
            return node
        case let .split(axis, children, fractions):
            return .split(axis: axis, children: children.map { swapLeaves($0, a, b) },
                          fractions: fractions)
        }
    }

    /// Ein Chat wird auf eine Zelle gezogen (Entscheidung F2).
    ///
    /// `replace` ersetzt den Inhalt, `stack` legt ihn dazu. Die Unterscheidung
    /// trifft die Oberflaeche anhand der Zone unter der Maus — die Engine
    /// bekommt sie fertig.
    static func drop(
        _ session: UUID,
        onto cellID: UUID,
        mode: DropMode,
        in layout: WorkspaceLayout
    ) -> WorkspaceLayout {
        guard let targetIndex = layout.cells.firstIndex(where: { $0.id == cellID }) else {
            return layout
        }
        var result = layout

        // Aus der alten Zelle nehmen — ein Chat liegt nur in einer Zelle
        // desselben Layouts (Invariante 3).
        result.cells = result.cells.map { cell in
            var cell = cell
            cell.sessions.removeAll { $0 == session }
            return cell
        }
        // Der Index kann sich durch das Entfernen nicht verschoben haben, weil
        // hier keine Zelle wegfaellt — leere Zellen raeumt erst der
        // Normalisierer am Ende ab.
        guard targetIndex < result.cells.count else { return LayoutNormalizer.normalize(result) }

        switch mode {
        case .replace:
            // Ersetzen heisst: der bisherige Inhalt weicht komplett. Bindungen
            // der Verdraengten sind damit gegenstandslos.
            for displaced in result.cells[targetIndex].sessions {
                result.bindings.removeValue(forKey: displaced)
            }
            result.cells[targetIndex].sessions = [session]
            result.cells[targetIndex].active = session

        case .stack:
            result.cells[targetIndex].sessions.append(session)
            result.cells[targetIndex].active = session
            if let anchor = result.cells[targetIndex].sessions.first, anchor != session {
                result.bindings[session] = anchor
            }
        }

        result.hidden.removeAll { $0 == session }
        return LayoutNormalizer.normalize(result)
    }

    /// Ein Chat wird auf eine Trennlinie gezogen (Entscheidung E7).
    ///
    /// Dort entsteht eine neue Flaeche — und die Anordnung wird dadurch
    /// `manual`, weil der Nutzer sie gerade selbst bestimmt hat. Das ist
    /// gewollt: Wer eine Kante trifft, will genau dort etwas haben, nicht
    /// „irgendwo, die Engine entscheidet".
    static func insert(
        _ session: UUID,
        atEdge edge: Edge,
        of cellID: UUID,
        in layout: WorkspaceLayout
    ) -> WorkspaceLayout {
        guard layout.cells.contains(where: { $0.id == cellID }) else { return layout }
        var result = layout

        result.cells = result.cells.map { cell in
            var cell = cell
            cell.sessions.removeAll { $0 == session }
            return cell
        }
        result.bindings.removeValue(forKey: session)

        let newCell = WorkspaceLayout.Cell(session: session)
        guard let anchorIndex = result.cells.firstIndex(where: { $0.id == cellID }) else {
            return LayoutNormalizer.normalize(result)
        }
        let insertIndex = edge.insertsBefore ? anchorIndex : anchorIndex + 1
        result.cells.insert(newCell, at: insertIndex)

        // Baum aufbauen: Bei `automatic` erst aus der aktuellen Anordnung einen
        // Baum machen, damit die bisherige Aufteilung erhalten bleibt.
        let base = result.arrangement.tree ?? automaticTree(for: layout.cells)
        result.arrangement = .manual(
            insertLeaf(newCell.id, atEdge: edge, besides: cellID, in: base)
        )
        result.hidden.removeAll { $0 == session }
        return LayoutNormalizer.normalize(result)
    }

    /// Fuegt ein Blatt neben einem bestehenden ein und teilt dabei dessen Platz.
    private static func insertLeaf(
        _ newCellID: UUID,
        atEdge edge: Edge,
        besides anchorID: UUID,
        in node: WorkspaceLayout.SplitNode
    ) -> WorkspaceLayout.SplitNode {
        switch node {
        case let .leaf(cellID) where cellID == anchorID:
            let leaves: [WorkspaceLayout.SplitNode] = edge.insertsBefore
                ? [.leaf(cellID: newCellID), node]
                : [node, .leaf(cellID: newCellID)]
            return .split(axis: edge.axis, children: leaves,
                          fractions: LayoutNormalizer.equalFractions(count: 2))

        case .leaf:
            return node

        case let .split(axis, children, fractions):
            // Liegt der Anker direkt hier UND passt die Achse, wird das neue
            // Blatt als Geschwister eingefuegt statt geschachtelt — sonst
            // entstehen bei jedem Einfuegen tiefere Baeume mit demselben Bild.
            if axis == edge.axis,
               let position = children.firstIndex(where: {
                   if case let .leaf(id) = $0 { return id == anchorID }
                   return false
               }) {
                var newChildren = children
                var newFractions = fractions.count == children.count
                    ? fractions
                    : LayoutNormalizer.equalFractions(count: children.count)

                // Der neue Nachbar teilt sich den Platz des Ankers.
                let anchorShare = newFractions[position]
                newFractions[position] = anchorShare / 2
                let insertAt = edge.insertsBefore ? position : position + 1
                newChildren.insert(.leaf(cellID: newCellID), at: insertAt)
                newFractions.insert(anchorShare / 2, at: insertAt)

                return .split(axis: axis, children: newChildren, fractions: newFractions)
            }

            return .split(
                axis: axis,
                children: children.map {
                    insertLeaf(newCellID, atEdge: edge, besides: anchorID, in: $0)
                },
                fractions: fractions
            )
        }
    }

    /// Zurueck zur automatischen Anordnung (Entscheidung F6).
    ///
    /// Der Baum wird verworfen, Zellen und Stapel bleiben. Das ist der
    /// sichtbare Schalter, ueber den Bestandsnutzer nach der Migration
    /// ueberhaupt erst in die neue Bedienung kommen — er darf nie versteckt
    /// sein.
    static func resetToAutomatic(_ layout: WorkspaceLayout) -> WorkspaceLayout {
        var result = layout
        result.arrangement = .automatic
        return LayoutNormalizer.normalize(result)
    }

    /// Baut aus einer Zellenliste einen flachen Baum — Grundlage, wenn aus
    /// `automatic` durch eine Nutzeraktion `manual` wird.
    static func automaticTree(for cells: [WorkspaceLayout.Cell]) -> WorkspaceLayout.SplitNode {
        guard let first = cells.first else { return .leaf(cellID: UUID()) }
        guard cells.count > 1 else { return .leaf(cellID: first.id) }
        let children = cells.map { WorkspaceLayout.SplitNode.leaf(cellID: $0.id) }
        return .split(axis: .horizontal, children: children,
                      fractions: LayoutNormalizer.equalFractions(count: children.count))
    }

    // MARK: - Sichtbarkeit

    /// Macht einen Chat in seiner Zelle sichtbar (Stapelwechsel).
    static func activate(_ session: UUID, in layout: WorkspaceLayout) -> WorkspaceLayout {
        guard let index = layout.cells.firstIndex(where: { $0.sessions.contains(session) }) else {
            return layout
        }
        var result = layout
        result.cells[index].active = session
        return result
    }
}
