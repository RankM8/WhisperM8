import CoreGraphics
import Foundation

/// Wo die Trenner eines manuellen Layouts liegen — und wie ein Zug daran
/// wirkt.
///
/// **Warum getrennt von `LayoutGeometry`:** Flaechen berechnen und Trenner
/// finden sind zwei Fragen. Die erste beantwortet jede Ansicht bei jedem Bild,
/// die zweite nur, solange gezogen wird. Getrennt bleibt beides einzeln
/// pruefbar, und die bestehende Geometrie muss nicht angefasst werden.
///
/// Ein Trenner wird ueber seine beiden **angrenzenden Zellen** benannt, nicht
/// ueber einen Pfad in den Baum. Ein Pfad wuerde bei jeder Umsortierung
/// ungueltig; die Nachbarschaft ueberlebt sie.
extension LayoutGeometry {

    /// Ein Trenner zwischen zwei benachbarten Kindern eines Splits.
    struct DividerHandle: Equatable, Identifiable {
        /// Der Griffbereich auf dem Bildschirm.
        let rect: CGRect
        /// Letztes Blatt links/oberhalb des Trenners.
        let leadingCellID: UUID
        /// Erstes Blatt rechts/unterhalb des Trenners.
        let trailingCellID: UUID
        let axis: WorkspaceLayout.Axis
        /// Laenge der geteilten Achse in Punkten — Bezugsgroesse, um einen
        /// Versatz in Anteile umzurechnen.
        let available: CGFloat

        /// ALLE Zellen des Zweigs links/oberhalb — beim Ziehen dehnt sich der
        /// ganze Zweig, nicht nur die angrenzende Flaeche. Bei einem
        /// verschachtelten Split haengen daran mehrere Terminals.
        let leadingCellIDs: [UUID]
        /// Alle Zellen des Zweigs rechts/unterhalb.
        let trailingCellIDs: [UUID]
        /// Das Rechteck des linken/oberen Zweigs — Bezug fuer den Dehnfaktor.
        let leadingRect: CGRect
        /// Das Rechteck des rechten/unteren Zweigs.
        let trailingRect: CGRect

        var id: String { "\(leadingCellID.uuidString)|\(trailingCellID.uuidString)" }
    }

    /// Wie breit der Griff ist. Schmaler als das, was man sieht: Der sichtbare
    /// Spalt betraegt einen Punkt, treffen muss man ihn trotzdem koennen.
    static let dividerHandleThickness: CGFloat = 8

    /// Alle Trenner eines Layouts. Bei `automatic` gibt es keine — dort ist die
    /// Aufteilung ein Ergebnis, kein Zustand, und waere nicht zu halten.
    static func dividers(
        for layout: WorkspaceLayout,
        in bounds: CGRect
    ) -> [DividerHandle] {
        guard case let .manual(tree) = layout.arrangement,
              bounds.width > 0, bounds.height > 0
        else { return [] }

        var result: [DividerHandle] = []
        collectDividers(tree, in: bounds, into: &result)
        return result
    }

    private static func collectDividers(
        _ node: WorkspaceLayout.SplitNode,
        in rect: CGRect,
        into result: inout [DividerHandle]
    ) {
        guard case let .split(axis, children, fractions) = node else { return }

        let shares = LayoutNormalizer.normalizedFractions(fractions, count: children.count)
        var offset: CGFloat = 0
        var childRects: [CGRect] = []

        // Dieselbe Rechnung wie in `place` — Kanten runden, Groesse daraus
        // ableiten. Weicht sie ab, sitzt der Griff neben dem Spalt.
        for (index, _) in children.enumerated() {
            let share = CGFloat(shares[index])
            switch axis {
            case .horizontal:
                let x0 = (rect.minX + offset).rounded()
                let x1 = (rect.minX + offset + rect.width * share).rounded()
                childRects.append(CGRect(x: x0, y: rect.minY.rounded(),
                                         width: x1 - x0, height: rect.height.rounded()))
                offset += rect.width * share
            case .vertical:
                let y0 = (rect.minY + offset).rounded()
                let y1 = (rect.minY + offset + rect.height * share).rounded()
                childRects.append(CGRect(x: rect.minX.rounded(), y: y0,
                                         width: rect.width.rounded(), height: y1 - y0))
                offset += rect.height * share
            }
        }

        for index in 0..<(children.count - 1) {
            guard let leading = children[index].leafIDs.last,
                  let trailing = children[index + 1].leafIDs.first
            else { continue }

            let vorher = childRects[index]
            let griff: CGRect
            switch axis {
            case .horizontal:
                griff = CGRect(
                    x: vorher.maxX - dividerHandleThickness / 2,
                    y: vorher.minY,
                    width: dividerHandleThickness,
                    height: vorher.height
                )
            case .vertical:
                griff = CGRect(
                    x: vorher.minX,
                    y: vorher.maxY - dividerHandleThickness / 2,
                    width: vorher.width,
                    height: dividerHandleThickness
                )
            }

            result.append(DividerHandle(
                rect: griff,
                leadingCellID: leading,
                trailingCellID: trailing,
                axis: axis,
                available: axis == .horizontal ? rect.width : rect.height,
                leadingCellIDs: children[index].leafIDs,
                trailingCellIDs: children[index + 1].leafIDs,
                leadingRect: childRects[index],
                trailingRect: childRects[index + 1]
            ))
        }

        // Tiefer liegende Splits liefern ihre eigenen Trenner.
        for (index, child) in children.enumerated() {
            collectDividers(child, in: childRects[index], into: &result)
        }
    }
}

/// Wendet einen Trenner-Zug auf den Baum an.
///
/// Getrennt von `LayoutDividerDrag`, weil dort der Zustand des Ziehens liegt
/// (Versatz, Grenzen) und hier die Aenderung am Layout. Beides zusammen waere
/// eine Zustandsmaschine, die nebenbei Baeume umbaut.
enum LayoutDividerApply {

    /// Verschiebt die Grenze zwischen zwei benachbarten Zellen.
    ///
    /// Findet den Split, dessen Kind `index` als letztes Blatt `leadingCellID`
    /// und dessen Kind `index + 1` als erstes Blatt `trailingCellID` hat —
    /// genau die Nachbarschaft, die `LayoutGeometry.dividers` gemeldet hat.
    /// Wird sie nicht gefunden (Layout hat sich waehrend des Zuges geaendert),
    /// bleibt das Layout unveraendert.
    static func apply(
        leadingCellID: UUID,
        trailingCellID: UUID,
        offset: CGFloat,
        available: CGFloat,
        in layout: WorkspaceLayout
    ) -> WorkspaceLayout {
        guard case let .manual(tree) = layout.arrangement, offset != 0, available > 0 else {
            return layout
        }

        var result = layout
        result.arrangement = .manual(
            resize(tree, leadingCellID: leadingCellID, trailingCellID: trailingCellID,
                   offset: offset, available: available)
        )
        return LayoutNormalizer.normalize(result)
    }

    private static func resize(
        _ node: WorkspaceLayout.SplitNode,
        leadingCellID: UUID,
        trailingCellID: UUID,
        offset: CGFloat,
        available: CGFloat
    ) -> WorkspaceLayout.SplitNode {
        guard case let .split(axis, children, fractions) = node else { return node }

        for index in 0..<max(children.count - 1, 0) {
            guard children[index].leafIDs.last == leadingCellID,
                  children[index + 1].leafIDs.first == trailingCellID
            else { continue }

            return .split(
                axis: axis,
                children: children,
                fractions: LayoutDividerDrag.resolvedFractions(
                    fractions: LayoutNormalizer.normalizedFractions(fractions, count: children.count),
                    index: index,
                    offset: offset,
                    available: available
                )
            )
        }

        // Nicht auf dieser Ebene — tiefer suchen.
        return .split(
            axis: axis,
            children: children.map {
                resize($0, leadingCellID: leadingCellID, trailingCellID: trailingCellID,
                       offset: offset, available: available)
            },
            fractions: fractions
        )
    }
}
