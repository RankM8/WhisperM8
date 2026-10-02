import SwiftUI

/// Markierung EINER Grid-Pane während des Ctrl+Tab-Durchlaufs (Situation A,
/// Plan `docs/plans/tab-switcher-workspace.md`, Slice S5): Nicht-Ziele leicht
/// abgedunkelt (~35 % Scrim), das Ziel mit Akzent-Rahmen (2 pt) und oben
/// links einem Status-Chip (`TabSwitcherTile` in kleiner Stufe).
///
/// Hängt UNBEDINGT als `.overlay` am Slot (die Fallunterscheidung steckt im
/// Body) — ein `if` am Slot änderte dessen View-Identität und remountete das
/// Terminal. Außerhalb des Durchlaufs rendert der Body nichts und ist damit
/// für Hit-Testing unsichtbar.
///
/// Performance: liest nur den kleinen `TabSwitcherGridMarkingState` — ein
/// Schritt invalidiert diese Overlays, nicht den Grid-Body. Status- und
/// Activity-Store beobachtet ausschließlich der Ziel-Chip
/// (`TabSwitcherGridTargetChip`), der nur am Ziel und nur während des
/// Durchlaufs existiert. Kein I/O, kein `.contextMenu`.
struct TabSwitcherGridPaneMarking: View {
    let marking: TabSwitcherGridMarkingState
    /// `nil` = leerer Slot.
    let sessionID: UUID?
    let title: String?
    let lastActivityAt: Date?
    /// Pane hat aktuell den Fokus (Ausgangspunkt des Durchlaufs, „Hier").
    let isCurrent: Bool
    let statusStore: AgentSessionRuntimeStatusStore
    let activityStore: AgentSessionActivityStore
    let onCommit: (UUID) -> Void
    let onCancel: () -> Void

    var body: some View {
        let role = TabSwitcherGridMarking.role(
            sessionID: sessionID,
            isActive: marking.isActive,
            highlightedID: marking.highlightedID
        )
        ZStack {
            switch role {
            case .inactive:
                EmptyView()
            case .dimmed:
                Rectangle()
                    .fill(Color.black.opacity(0.35))
                    .allowsHitTesting(false)
                clickCatcher
            case .target:
                Rectangle()
                    .strokeBorder(AgentTheme.accent, lineWidth: 2)
                    .allowsHitTesting(false)
                clickCatcher
                if let sessionID {
                    chipLayer(sessionID: sessionID)
                }
            }
        }
        .animation(.easeOut(duration: 0.1), value: role)
    }

    /// Klick auf eine Pane während des Durchlaufs = sofortiger Commit; auf
    /// einen leeren Slot oder einen Übernahme-Platzhalter (nicht im Umfang)
    /// = Abbruch. NSView-Catcher statt `onTapGesture` — sonst könnte der
    /// Klick als Maus-Escape-Sequenz in der laufenden TUI landen (Begründung
    /// an `GridPaneClickCatcher`).
    private var clickCatcher: some View {
        GridPaneClickCatcher(isArmed: true) {
            if let sessionID, marking.targetIDs.contains(sessionID) {
                onCommit(sessionID)
            } else {
                onCancel()
            }
        }
        .accessibilityHidden(true)
    }

    private func chipLayer(sessionID: UUID) -> some View {
        GeometryReader { geo in
            if let chip = TabSwitcherGridMarking.chip(forPaneSize: geo.size) {
                TabSwitcherGridTargetChip(
                    sessionID: sessionID,
                    title: title ?? "Chat",
                    lastActivityAt: lastActivityAt,
                    isCurrent: isCurrent,
                    chip: chip,
                    statusStore: statusStore,
                    activityStore: activityStore
                )
                .padding(TabSwitcherGridMarking.chipInset)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Status-Chip der Ziel-Pane. Einzige Stelle der Grid-Markierung, die die
/// Stores beobachtet — existiert nur am Ziel und nur während des Durchlaufs.
/// Die Dauer tickt per `TimelineView`, solange er sichtbar ist.
struct TabSwitcherGridTargetChip: View {
    let sessionID: UUID
    let title: String
    let lastActivityAt: Date?
    let isCurrent: Bool
    let chip: TabSwitcherGridMarking.Chip
    @ObservedObject var statusStore: AgentSessionRuntimeStatusStore
    @ObservedObject var activityStore: AgentSessionActivityStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            TabSwitcherTile(
                model: TabSwitcherTileModel(
                    title: title,
                    status: statusStore.status(for: sessionID),
                    activity: activityStore.activity(for: sessionID),
                    statusSince: activityStore.statusSince(for: sessionID),
                    lastActivityAt: lastActivityAt,
                    now: context.date
                ),
                detail: chip.detail,
                arrangement: .card,
                isHighlighted: true,
                isCurrent: isCurrent
            )
        }
        .frame(width: chip.size.width, height: chip.size.height)
        // Deckender Grund unter der getönten Kachel — sie liegt über
        // laufendem Terminal-Text und muss trotzdem lesbar bleiben.
        .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.30), radius: 12, y: 4)
    }
}
