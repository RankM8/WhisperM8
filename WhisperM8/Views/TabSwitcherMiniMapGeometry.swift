import CoreGraphics
import Foundation
import SwiftUI

/// Geometrie der Mini-Map im Ctrl+Tab-Switcher (Situation B, Plan
/// `docs/plans/tab-switcher-workspace.md`, Slice S4). Pure Logik,
/// unit-getestet in `TabSwitcherMiniMapGeometryTests`.
///
/// **Keine eigene Geometrie-Tabelle:** Die Rechtecke entstehen aus genau
/// denselben Bausteinen wie der Grid-Renderer (`AgentGridSplitContainer`) —
/// Zeilen-Blöcke aus `AgentGridSplitContainer.blocks(inRow:layout:)`, Spurmaße
/// aus `GridSplitResolver.trackSizes` mit den Gewichten der Entity. Eine
/// zweite Tabelle wäre die zehnte Quelle (vgl. `grid-smart-layout.md`).
///
/// **Warum in der Grid-Fläche rechnen und dann skalieren:** `trackSizes`
/// clampt jede Spur auf `GridSplitResolver.minPane` (240 pt). Direkt in der
/// kleinen Mini-Map-Fläche gerechnet, griffe dieser Clamp fast immer und
/// verteilte die Spuren gleichmäßig — die Mini-Map zeigte dann ein anderes
/// Raster als das echte Grid. Deshalb: erst das Raster in der echten
/// Grid-Größe auflösen, dann auf die Zielfläche skalieren.
enum TabSwitcherMiniMapGeometry {
    /// Rechteck eines Slots in der Zielfläche (Ursprung oben links).
    struct SlotRect: Equatable {
        let slot: Int
        let row: Int
        /// Überdeckte Spalten-Spuren (Spann-Slots laufen über mehrere).
        let tracks: ClosedRange<Int>
        let rect: CGRect
    }

    // MARK: - Slot-Rechtecke

    /// Rechteck je Slot der Entity — genau `capacity` Einträge, nach
    /// Slot-Index aufsteigend (= Leserichtung). Leere Slots sind enthalten
    /// (die Mini-Map zeigt das Layout, nicht nur die Belegung); welche Slots
    /// angesprungen werden, entscheidet der Scope.
    ///
    /// - Parameters:
    ///   - gridSize: Größe der echten Grid-Fläche (bzw. des Content-Bereichs,
    ///     in dem das Grid stünde). Bestimmt das Spur-Clamping.
    ///   - targetSize: Größe der Mini-Map. Skaliert wird je Achse; bei gleichem
    ///     Seitenverhältnis (siehe `mapSize`) ist das eine einheitliche Skalierung.
    static func slotRects(
        for entity: AgentGridWorkspace,
        gridSize: CGSize,
        targetSize: CGSize
    ) -> [SlotRect] {
        let layout = AgentGridAutoLayout.forCapacity(entity.capacity)
        let gridRects = slotRects(
            layout: layout,
            columnFractions: entity.columnFractions,
            rowFractions: entity.rowFractions,
            in: gridSize
        )
        let scaleX = gridSize.width > 0 ? targetSize.width / gridSize.width : 0
        let scaleY = gridSize.height > 0 ? targetSize.height / gridSize.height : 0
        return gridRects.map { slotRect in
            SlotRect(
                slot: slotRect.slot,
                row: slotRect.row,
                tracks: slotRect.tracks,
                rect: CGRect(
                    x: slotRect.rect.minX * scaleX,
                    y: slotRect.rect.minY * scaleY,
                    width: slotRect.rect.width * scaleX,
                    height: slotRect.rect.height * scaleY
                )
            )
        }
    }

    /// Unskalierte Slot-Rechtecke eines Layouts in der Grid-Fläche `size` —
    /// so, wie der Renderer sie zeichnet (1-pt-Trennlinien zwischen Spuren,
    /// ein Block über mehrere Spuren schluckt die Trennlinien dazwischen).
    /// Gewichte mit falscher Anzahl fallen — wie im Renderer
    /// (`effectiveColumnFractions`) — auf Gleichverteilung zurück.
    static func slotRects(
        layout: AgentGridAutoLayout,
        columnFractions: [Double],
        rowFractions: [Double],
        in size: CGSize
    ) -> [SlotRect] {
        let columns = columnFractions.count == layout.columns
            ? columnFractions
            : AgentGridWorkspace.equalFractions(count: layout.columns)
        let rows = rowFractions.count == layout.rows
            ? rowFractions
            : AgentGridWorkspace.equalFractions(count: layout.rows)
        let colSizes = GridSplitResolver.trackSizes(total: size.width, fractions: columns)
        let rowSizes = GridSplitResolver.trackSizes(total: size.height, fractions: rows)
        let divider = GridSplitResolver.divider

        var result: [SlotRect] = []
        for row in 0 ..< layout.rows {
            guard rowSizes.indices.contains(row) else { continue }
            let y = offset(of: row, in: rowSizes, divider: divider)
            for block in AgentGridSplitContainer<EmptyView>.blocks(inRow: row, layout: layout) {
                let x = offset(of: block.tracks.lowerBound, in: colSizes, divider: divider)
                let width = block.tracks.reduce(CGFloat(0)) { summe, index in
                    summe + (colSizes.indices.contains(index) ? colSizes[index] : 0)
                } + divider * CGFloat(block.tracks.count - 1)
                result.append(SlotRect(
                    slot: block.slot,
                    row: row,
                    tracks: block.tracks,
                    rect: CGRect(x: x, y: y, width: width, height: rowSizes[row])
                ))
            }
        }
        return result.sorted { $0.slot < $1.slot }
    }

    /// Startposition der Spur `index`: Summe der Spuren davor plus die
    /// passierten Trennlinien.
    private static func offset(of index: Int, in sizes: [CGFloat], divider: CGFloat) -> CGFloat {
        sizes.prefix(index).reduce(0, +) + divider * CGFloat(index)
    }

    // MARK: - Größe der Mini-Map

    /// Höchstens dieser Anteil des Content-Bereichs je Achse.
    static let maxContentFraction: CGFloat = 0.7
    /// Mindestgröße einer 1/9-Kachel (Drittel je Achse), ab der die
    /// Stand-Zeile Platz hat.
    static let minimumNinthTile = CGSize(width: 150, height: 72)

    /// Größe der Mini-Map für einen Content-Bereich.
    ///
    /// - Seitenverhältnis = Content-Bereich (dann ist die Skalierung in
    ///   `slotRects(for:gridSize:targetSize:)` einheitlich, die Kacheln
    ///   verzerren nicht).
    /// - Regulär 70 % des Content-Bereichs je Achse.
    /// - Ist eine 1/9-Kachel (Breite/3 × Höhe/3) dann kleiner als
    ///   150 × 72 pt, wächst die Map bis zu dieser Mindestgröße — aber nie
    ///   über den Content-Bereich hinaus. Reicht auch der nicht, entfällt die
    ///   Stand-Zeile (`tileDetail`), die Map bleibt so groß wie möglich.
    static func mapSize(contentSize: CGSize) -> CGSize {
        guard contentSize.width > 0, contentSize.height > 0 else { return .zero }
        // Faktor, ab dem eine 1/9-Kachel die Mindestgröße erreicht.
        let minimumFactor = max(
            minimumNinthTile.width * 3 / contentSize.width,
            minimumNinthTile.height * 3 / contentSize.height
        )
        let factor = min(1, max(maxContentFraction, minimumFactor))
        return CGSize(width: contentSize.width * factor, height: contentSize.height * factor)
    }

    /// Größe der Mini-Map, wenn um sie herum noch Chrome (Titel, Footer,
    /// Paddings der Karte) in den Content-Bereich passen muss: erst
    /// `mapSize(contentSize:)`, dann — falls Map + Chrome den Bereich
    /// sprengen — einheitlich verkleinert, sodass das Seitenverhältnis
    /// erhalten bleibt. Wird es dadurch eng, greift `tileDetail` (die
    /// Stand-Zeile entfällt, nie der Status).
    static func fittedMapSize(contentSize: CGSize, chrome: CGSize) -> CGSize {
        let map = mapSize(contentSize: contentSize)
        guard map.width > 0, map.height > 0 else { return .zero }
        let availableWidth = max(0, contentSize.width - chrome.width)
        let availableHeight = max(0, contentSize.height - chrome.height)
        let factor = min(1, availableWidth / map.width, availableHeight / map.height)
        return CGSize(width: map.width * factor, height: map.height * factor)
    }

    // MARK: - Räumliche Pfeil-Navigation

    /// Ziel einer Pfeiltaste in der Mini-Map — dieselbe Logik wie die
    /// ⌃⌘-Pfeile im Grid (`GridFocusNavigator`): rechts/links in der Zeile,
    /// oben/unten entlang der Spalte. Nur Slots, deren Session im
    /// Durchlauf-Umfang (`order`) liegt, zählen als belegt — leere Slots und
    /// Übernahme-Platzhalter werden in der Richtung übersprungen.
    ///
    /// Ohne Highlight (bzw. Highlight nicht im Workspace) startet die Suche
    /// beim ersten Ziel des Umfangs. `nil` = in dieser Richtung kein Ziel
    /// (die Taste bleibt dann wirkungslos, kein Wrap-around).
    static func spatialTarget(
        from highlightedID: UUID?,
        direction: GridFocusDirection,
        in entity: AgentGridWorkspace,
        order: [UUID]
    ) -> UUID? {
        let eligible = Set(order)
        guard let startID = highlightedID.flatMap({ eligible.contains($0) ? $0 : nil }) ?? order.first,
              let startIndex = entity.slotIndex(of: startID) else { return nil }
        let occupied = entity.slots.map { slot in slot.map { eligible.contains($0) } ?? false }
        guard let targetIndex = GridFocusNavigator.target(
            from: startIndex,
            direction: direction,
            layout: AgentGridAutoLayout.forCapacity(entity.capacity),
            occupied: occupied
        ), entity.slots.indices.contains(targetIndex) else { return nil }
        return entity.slots[targetIndex]
    }

    // MARK: - Detailstufe einer Kachel

    /// Mindestgröße einer Kachel, ab der neben Status + Titel noch die Dauer
    /// Platz hat („arbeitet · 12 min" in einer Zeile + Titel darunter).
    static let minimumDurationTile = CGSize(width: 130, height: 52)

    /// Stufe aus der tatsächlichen Kachelgröße (Spann- und Gewichts-Kacheln
    /// können größer sein als eine 1/9-Kachel und behalten die Zeile dann).
    /// Die Stufen selbst sind die gemeinsame `TabSwitcherTileDetail` der
    /// Kachel — keine eigene Definition hier. Der Status bleibt in jeder
    /// Stufe; weggelassen werden erst die Stand-Zeile, dann die Dauer.
    static func tileDetail(for tileSize: CGSize) -> TabSwitcherTileDetail {
        if tileSize.width >= minimumNinthTile.width && tileSize.height >= minimumNinthTile.height {
            return .full
        }
        if tileSize.width >= minimumDurationTile.width && tileSize.height >= minimumDurationTile.height {
            return .withoutActivity
        }
        return .statusAndTitle
    }
}
