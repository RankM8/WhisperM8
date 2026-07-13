import SwiftUI

/// Eigenes Grid-Subview für die Pane-Anordnung samt Divider-Griffen —
/// Perf-Entkopplung (Plan F2, Blaupause ff489fdb): Der Divider-Drag lebt
/// komplett in diesem Teilbaum. Jeder Maus-Tick aktualisiert nur den
/// nicht-observierten Live-Wert (`DragState`, Referenztyp — KEIN `@State`-Write
/// pro Tick, sonst invalidierte früher jeder Tick den gesamten Fenster-Body
/// und `headerTabs` wurde ~12× neu berechnet). Eine einzelne cancellable
/// `@MainActor`-Task-Schleife übernimmt den jeweils neuesten Wert alle 33 ms
/// in das gelesene `applied…`-Paar (Latest-Value-Sampling), persistiert wird
/// genau einmal beim Loslassen über die Commit-Closures.
///
/// Seit Paket 3 (F10) arbeitet der Container mit GEWICHTS-VEKTOREN pro Achse
/// (2–3 Spuren, Kapazitäten 2/3/4/6/9): Divider `i` verschiebt Anteil nur
/// zwischen den Spuren `i` und `i+1` (`GridSplitResolver.fractionsDuringDrag`).
struct AgentGridSplitContainer<Pane: View>: View {
    let layout: AgentGridAutoLayout
    /// Persistierte Gewichts-Vektoren (Quelle: `AgentGridWorkspace`).
    let persistedColumnFractions: [Double]
    let persistedRowFractions: [Double]
    let commitColumnFractions: ([Double]) -> Void
    let commitRowFractions: ([Double]) -> Void
    /// Griff-Hover unterdrückt beim Aufrufer das Pane-Klick-Routing.
    let onHandleHoverChanged: (Bool) -> Void
    @ViewBuilder let pane: (Int) -> Pane

    /// Live-Zustand eines aktiven Drags — bewusst ein Referenztyp mit platten
    /// Feldern: Mutationen triggern keine SwiftUI-Invalidierung.
    final class DragState {
        var columnBase: [Double]?
        var rowBase: [Double]?
        var liveColumns: [Double]?
        var liveRows: [Double]?
        var sampler: Task<Void, Never>?
    }

    @State private var drag = DragState()
    /// Die von den Pane-Frames gelesenen Vektoren — höchstens alle 33 ms
    /// gesetzt. `nil` außerhalb eines Drags (dann gelten die persistierten).
    @State private var appliedColumnFractions: [Double]?
    @State private var appliedRowFractions: [Double]?

    private var effectiveColumnFractions: [Double] {
        let fractions = appliedColumnFractions ?? persistedColumnFractions
        return fractions.count == layout.columns
            ? fractions
            : AgentGridWorkspace.equalFractions(count: layout.columns)
    }

    private var effectiveRowFractions: [Double] {
        let fractions = appliedRowFractions ?? persistedRowFractions
        return fractions.count == layout.rows
            ? fractions
            : AgentGridWorkspace.equalFractions(count: layout.rows)
    }

    var body: some View {
        GeometryReader { geo in
            arrangement(in: geo.size)
        }
        // Nach einem Commit läuft der neue persistierte Wert durch den
        // Parent zurück — erst DANN darf `applied…` losgelassen werden
        // (sonst fiele der effektive Wert für einen Frame auf den alten
        // persistierten zurück). Externe Änderungen (anderes Fenster,
        // Doppelklick-Reset) übernehmen wir ebenso, solange kein Drag läuft.
        .onChange(of: persistedColumnFractions) { _, _ in
            if drag.columnBase == nil { appliedColumnFractions = nil }
        }
        .onChange(of: persistedRowFractions) { _, _ in
            if drag.rowBase == nil { appliedRowFractions = nil }
        }
        .onDisappear { cancelSampler() }
    }

    // MARK: - Anordnung (1-px-Divider, Griffe als Overlays)

    @ViewBuilder
    private func arrangement(in size: CGSize) -> some View {
        let colSizes = GridSplitResolver.trackSizes(
            total: size.width, fractions: effectiveColumnFractions
        )
        let rowSizes = GridSplitResolver.trackSizes(
            total: size.height, fractions: effectiveRowFractions
        )
        gridBody(colSizes: colSizes, rowSizes: rowSizes)
            .overlay {
                columnHandles(colSizes: colSizes, rowSizes: rowSizes, totalWidth: size.width)
            }
            .overlay {
                rowHandles(rowSizes: rowSizes, totalHeight: size.height)
            }
    }

    @ViewBuilder
    private func gridBody(colSizes: [CGFloat], rowSizes: [CGFloat]) -> some View {
        let columns = layout.columns
        let rows = layout.rows
        VStack(spacing: 1) {
            ForEach(0 ..< rows, id: \.self) { row in
                HStack(spacing: 1) {
                    // twoPlusOne: die untere Pane läuft in voller Breite durch.
                    if layout == .twoPlusOne, row == 1 {
                        pane(2)
                    } else {
                        ForEach(0 ..< columns, id: \.self) { column in
                            let index = row * columns + column
                            if column < columns - 1 {
                                pane(index).frame(width: colSizes[column])
                            } else {
                                // Letzte Spur füllt — nimmt den Rundungsrest.
                                pane(index)
                            }
                        }
                    }
                }
                .frame(height: row < rows - 1 ? rowSizes[row] : nil)
            }
        }
    }

    /// Spalten-Griffe an jeder inneren Spaltengrenze. Bei `twoPlusOne` nur
    /// über der oberen Reihe (unten läuft die Pane in voller Breite durch).
    @ViewBuilder
    private func columnHandles(colSizes: [CGFloat], rowSizes: [CGFloat], totalWidth: CGFloat) -> some View {
        ForEach(0 ..< max(0, layout.columns - 1), id: \.self) { dividerIndex in
            let offset = cumulativeOffset(colSizes, upTo: dividerIndex)
            columnHandle(dividerIndex: dividerIndex, totalWidth: totalWidth)
                .frame(height: layout == .twoPlusOne ? rowSizes.first : nil)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: layout == .twoPlusOne ? .infinity : nil,
                    alignment: layout == .twoPlusOne ? .topLeading : .leading
                )
                .offset(x: offset - 4)
        }
    }

    @ViewBuilder
    private func rowHandles(rowSizes: [CGFloat], totalHeight: CGFloat) -> some View {
        ForEach(0 ..< max(0, layout.rows - 1), id: \.self) { dividerIndex in
            rowHandle(dividerIndex: dividerIndex, totalHeight: totalHeight)
                .frame(maxHeight: .infinity, alignment: .top)
                .offset(y: cumulativeOffset(rowSizes, upTo: dividerIndex) - 4)
        }
    }

    /// x/y-Position des Dividers `index`: Summe der Spuren davor plus die
    /// bereits passierten 1-px-Divider.
    private func cumulativeOffset(_ sizes: [CGFloat], upTo dividerIndex: Int) -> CGFloat {
        sizes.prefix(dividerIndex + 1).reduce(0, +) + CGFloat(dividerIndex)
    }

    private func columnHandle(dividerIndex: Int, totalWidth: CGFloat) -> some View {
        GridSplitHandle(
            axis: .column,
            onDragChanged: { translation in
                if drag.columnBase == nil { drag.columnBase = effectiveColumnFractions }
                guard let base = drag.columnBase else { return }
                drag.liveColumns = GridSplitResolver.fractionsDuringDrag(
                    base: base, dividerIndex: dividerIndex,
                    translation: translation, total: totalWidth
                )
                startSamplerIfNeeded()
            },
            onDragEnded: { endDrag(axis: .column) },
            onDoubleClick: {
                // Sofort lokal auf Gleichverteilung, Commit läuft hinterher
                // (onChange räumt `applied` nach dem Roundtrip).
                let equal = AgentGridWorkspace.equalFractions(count: layout.columns)
                appliedColumnFractions = equal
                commitColumnFractions(equal)
            },
            onHoverChanged: onHandleHoverChanged
        )
    }

    private func rowHandle(dividerIndex: Int, totalHeight: CGFloat) -> some View {
        GridSplitHandle(
            axis: .row,
            onDragChanged: { translation in
                if drag.rowBase == nil { drag.rowBase = effectiveRowFractions }
                guard let base = drag.rowBase else { return }
                drag.liveRows = GridSplitResolver.fractionsDuringDrag(
                    base: base, dividerIndex: dividerIndex,
                    translation: translation, total: totalHeight
                )
                startSamplerIfNeeded()
            },
            onDragEnded: { endDrag(axis: .row) },
            onDoubleClick: {
                let equal = AgentGridWorkspace.equalFractions(count: layout.rows)
                appliedRowFractions = equal
                commitRowFractions(equal)
            },
            onHoverChanged: onHandleHoverChanged
        )
    }

    // MARK: - Latest-Value-Sampling (33 ms)

    /// Genau EINE Sampler-Schleife pro aktivem Drag — kein Debounce pro Event,
    /// kein Timer (RunLoop-Mode-Fragen), kein DisplayLink (für 30 Hz unnötig).
    private func startSamplerIfNeeded() {
        guard drag.sampler == nil else { return }
        drag.sampler = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled else { return }
                applyLatestLiveValues()
            }
        }
    }

    /// Übernimmt die neuesten Live-Werte in die gelesenen `applied…`-Werte —
    /// DAS ist der eigentliche Layout-Tick, den `grid.dividerTick` misst
    /// (Zuweisung + folgender SwiftUI/AppKit-Layout-Pass bis zum nächsten
    /// Main-Queue-Turn).
    private func applyLatestLiveValues() {
        let nextColumns = drag.liveColumns
        let nextRows = drag.liveRows
        let columnsChanged = nextColumns != nil && nextColumns != appliedColumnFractions
        let rowsChanged = nextRows != nil && nextRows != appliedRowFractions
        guard columnsChanged || rowsChanged else { return }

        PerfSignposts.grid.emitEvent("grid.divider.layoutTick")
        let token = PerfBudgets.gridDividerTick.begin()
        if columnsChanged, let nextColumns { appliedColumnFractions = nextColumns }
        if rowsChanged, let nextRows { appliedRowFractions = nextRows }
        DispatchQueue.main.async {
            PerfBudgets.gridDividerTick.end(token)
        }
    }

    private enum DragAxis { case column, row }

    /// Drag-Ende: finalen Live-Wert ZUERST lokal anwenden (endet der Drag
    /// vor dem nächsten 33-ms-Tick, war er noch nie in `applied…`), dann
    /// genau EINMAL persistieren. `applied…` bleibt gesetzt, bis der neue
    /// persistierte Wert durch den Parent zurückläuft (`onChange` im Body) —
    /// kein Ein-Frame-Rückfall auf den alten Wert.
    private func endDrag(axis: DragAxis) {
        switch axis {
        case .column:
            if let live = drag.liveColumns {
                appliedColumnFractions = live
                commitColumnFractions(live)
            }
            drag.columnBase = nil
            drag.liveColumns = nil
        case .row:
            if let live = drag.liveRows {
                appliedRowFractions = live
                commitRowFractions(live)
            }
            drag.rowBase = nil
            drag.liveRows = nil
        }
        PerfSignposts.grid.emitEvent("grid.divider.commit")
        if drag.columnBase == nil, drag.rowBase == nil {
            cancelSampler()
        }
    }

    private func cancelSampler() {
        drag.sampler?.cancel()
        drag.sampler = nil
    }
}
