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
struct AgentGridSplitContainer<Pane: View>: View {
    let layout: AgentGridAutoLayout
    /// Persistierte Wunschwerte (Quelle: @AppStorage beim Aufrufer; ab
    /// Paket 2 die Fraction-Arrays des Workspace-Entities).
    let persistedColumnFraction: Double
    let persistedRowFraction: Double
    let commitColumnFraction: (Double) -> Void
    let commitRowFraction: (Double) -> Void
    /// Griff-Hover unterdrückt beim Aufrufer das Pane-Klick-Routing.
    let onHandleHoverChanged: (Bool) -> Void
    @ViewBuilder let pane: (Int) -> Pane

    /// Live-Zustand eines aktiven Drags — bewusst ein Referenztyp mit platten
    /// Feldern: Mutationen triggern keine SwiftUI-Invalidierung.
    final class DragState {
        var columnBase: CGFloat?
        var rowBase: CGFloat?
        var liveColumn: Double?
        var liveRow: Double?
        var sampler: Task<Void, Never>?
    }

    @State private var drag = DragState()
    /// Die von den Pane-Frames gelesenen Werte — höchstens alle 33 ms gesetzt.
    /// `nil` außerhalb eines Drags (dann gelten die persistierten Werte).
    @State private var appliedColumnFraction: Double?
    @State private var appliedRowFraction: Double?

    private var effectiveColumnFraction: Double { appliedColumnFraction ?? persistedColumnFraction }
    private var effectiveRowFraction: Double { appliedRowFraction ?? persistedRowFraction }

    var body: some View {
        GeometryReader { geo in
            arrangement(in: geo.size)
        }
        .onDisappear { cancelSampler() }
    }

    // MARK: - Anordnung (1-px-Divider, Griffe als Overlays)

    @ViewBuilder
    private func arrangement(in size: CGSize) -> some View {
        let colW = GridSplitResolver.firstSize(total: size.width, fraction: effectiveColumnFraction)
        let rowH = GridSplitResolver.firstSize(total: size.height, fraction: effectiveRowFraction)
        switch layout {
        case .single:
            // Vom Aufrufer nie mit 1 Pane verwendet (isGridActive) —
            // defensiver Fallback.
            EmptyView()
        case .cols2:
            HStack(spacing: 1) {
                pane(0).frame(width: colW)
                pane(1)
            }
            .overlay(alignment: .leading) {
                columnHandle(totalWidth: size.width).offset(x: colW - 4)
            }
        case .twoPlusOne:
            VStack(spacing: 1) {
                HStack(spacing: 1) {
                    pane(0).frame(width: colW)
                    pane(1)
                }
                .frame(height: rowH)
                // Spalten-Griff nur über der oberen Reihe — die untere Pane
                // läuft in voller Breite durch.
                .overlay(alignment: .leading) {
                    columnHandle(totalWidth: size.width).offset(x: colW - 4)
                }
                pane(2)
            }
            .overlay(alignment: .top) {
                rowHandle(totalHeight: size.height).offset(y: rowH - 4)
            }
        case .grid2x2:
            VStack(spacing: 1) {
                HStack(spacing: 1) {
                    pane(0).frame(width: colW)
                    pane(1)
                }
                .frame(height: rowH)
                HStack(spacing: 1) {
                    pane(2).frame(width: colW)
                    pane(3)
                }
            }
            // EIN Verhältnis pro Achse: der Spalten-Griff verschiebt beide
            // Reihen gemeinsam — das Grid bleibt ein Raster.
            .overlay(alignment: .leading) {
                columnHandle(totalWidth: size.width).offset(x: colW - 4)
            }
            .overlay(alignment: .top) {
                rowHandle(totalHeight: size.height).offset(y: rowH - 4)
            }
        }
    }

    private func columnHandle(totalWidth: CGFloat) -> some View {
        GridSplitHandle(
            axis: .column,
            onDragChanged: { translation in
                if drag.columnBase == nil {
                    drag.columnBase = GridSplitResolver.firstSize(
                        total: totalWidth, fraction: effectiveColumnFraction
                    )
                }
                guard let base = drag.columnBase else { return }
                drag.liveColumn = GridSplitResolver.fractionDuringDrag(
                    startFirstSize: base, translation: translation, total: totalWidth
                )
                startSamplerIfNeeded()
            },
            onDragEnded: { endDrag(axis: .column) },
            onDoubleClick: {
                appliedColumnFraction = nil
                commitColumnFraction(GridSplitResolver.defaultFraction)
            },
            onHoverChanged: onHandleHoverChanged
        )
    }

    private func rowHandle(totalHeight: CGFloat) -> some View {
        GridSplitHandle(
            axis: .row,
            onDragChanged: { translation in
                if drag.rowBase == nil {
                    drag.rowBase = GridSplitResolver.firstSize(
                        total: totalHeight, fraction: effectiveRowFraction
                    )
                }
                guard let base = drag.rowBase else { return }
                drag.liveRow = GridSplitResolver.fractionDuringDrag(
                    startFirstSize: base, translation: translation, total: totalHeight
                )
                startSamplerIfNeeded()
            },
            onDragEnded: { endDrag(axis: .row) },
            onDoubleClick: {
                appliedRowFraction = nil
                commitRowFraction(GridSplitResolver.defaultFraction)
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
        let nextColumn = drag.liveColumn
        let nextRow = drag.liveRow
        let columnChanged = nextColumn != nil && nextColumn != appliedColumnFraction
        let rowChanged = nextRow != nil && nextRow != appliedRowFraction
        guard columnChanged || rowChanged else { return }

        PerfSignposts.grid.emitEvent("grid.divider.layoutTick")
        let token = PerfBudgets.gridDividerTick.begin()
        if columnChanged, let nextColumn { appliedColumnFraction = nextColumn }
        if rowChanged, let nextRow { appliedRowFraction = nextRow }
        DispatchQueue.main.async {
            PerfBudgets.gridDividerTick.end(token)
        }
    }

    private enum DragAxis { case column, row }

    /// Drag-Ende: finalen Live-Wert sofort anwenden, genau EINMAL
    /// persistieren, Live-State räumen. `applied…` geht zurück auf `nil` —
    /// der soeben committete persistierte Wert ist identisch, es gibt keinen
    /// sichtbaren Sprung.
    private func endDrag(axis: DragAxis) {
        switch axis {
        case .column:
            if let live = drag.liveColumn { commitColumnFraction(live) }
            drag.columnBase = nil
            drag.liveColumn = nil
            appliedColumnFraction = nil
        case .row:
            if let live = drag.liveRow { commitRowFraction(live) }
            drag.rowBase = nil
            drag.liveRow = nil
            appliedRowFraction = nil
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
