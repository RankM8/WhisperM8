import SwiftUI

/// Ctrl+Tab-Umschalter: Overlay über dem Terminal-Content der Agent-Chats.
/// Liegt bewusst NUR über dem Content-Bereich (Anker: die Session-Group in
/// `mainWorkspace`) — Sidebar und Tab-Strip bleiben sichtbar und bedienbar.
///
/// Darstellung (Plan `docs/plans/tab-switcher-workspace.md`): jede Zelle ist
/// eine `TabSwitcherTile` mit Status (Wort + Symbol + Tönung), Titel,
/// Stand-Zeile und Dauer.
/// - `.list` (Situation C, Projekt-Liste): eine Spalte Kacheln in voller
///   Listenbreite (`TabSwitcherListLayout`), ↑/↓ = eine Zeile.
/// - `.grid` (Situation A/B, übergangsweise bis S4b/S5): Karten-Grid mit
///   Umbruch (`TabSwitcherGridLayout`), ↑/↓ = eine Grid-Reihe.
/// Erst wenn die Zeilen den verfügbaren Platz sprengen, scrollt der Inhalt
/// vertikal und hält das Highlight in Sicht.
///
/// Interaktion:
/// - Tastatur (Ctrl+Tab / Ctrl+Shift+Tab / ←→↑↓ / Esc / Return) läuft komplett
///   über die NSEvent-Monitore in `AgentChatsView+Shortcuts` — diese View
///   rendert nur den Zustand (`highlightedID`) und meldet die aktuelle
///   Spaltenzahl für die ↑/↓-Schrittweite zurück (`onColumnsChange`).
/// - Maus: Klick auf eine Kachel = sofortiger Commit (auch bei gehaltenem
///   Ctrl), Klick auf den Scrim = Abbruch. Hover verstärkt eine Kachel nur
///   visuell und verschiebt NIE das Keyboard-Highlight — sonst kämpfen
///   Mausposition und Tab-Taste um das Highlight und ein Ctrl-Loslassen
///   committet überraschend den gehoverten statt den ertabbten Chat.
///
/// Performance: rein speicherbasiert — Status, Stand-Zeile und `statusSince`
/// sind Dictionary-Lookups je angezeigter Session, kein Transcript-Read, kein
/// Scan über alle Sessions. Beide Stores werden HIER als `@ObservedObject`
/// beobachtet: das invalidiert nur diese Overlay-View (sie existiert nur
/// während des Umschaltens), nicht den AgentChatsView-Body. Die
/// AgentChatsView reicht die Stores nur als Referenz durch (computed
/// Property, kein Property-Wrapper) — die P4-Regel „Body liest `.statuses`
/// nie direkt" und die Plan-Regel „nur der Switcher beobachtet den
/// Activity-Store" bleiben gewahrt. Die Dauer tickt per `TimelineView` nur,
/// solange das Overlay offen ist.
struct AgentTabSwitcherOverlay: View {
    enum Presentation: Equatable {
        /// Situation C: Projekt-Liste, eine Spalte.
        case list
        /// Situation A/B (übergangsweise): Karten-Grid.
        case grid
    }

    /// Ziele des Durchlaufs in Umfangs-Reihenfolge (`TabSwitcherScope`:
    /// Grid-Slots, Workspace-Slots oder offene Tabs desselben Projekts).
    let sessions: [AgentChatSession]
    let highlightedID: UUID?
    /// Chat, von dem der Durchlauf ausging — trägt das „Hier"-Zeichen.
    let currentID: UUID?
    let presentation: Presentation
    @ObservedObject var statusStore: AgentSessionRuntimeStatusStore
    @ObservedObject var activityStore: AgentSessionActivityStore
    let onCommit: (UUID) -> Void
    let onCancel: () -> Void
    /// Meldet die aktuell gerenderte Spaltenzahl an die AgentChatsView —
    /// die ↑/↓-Navigation in `+Shortcuts` springt damit exakt eine
    /// Reihe (Schrittweite = Spalten, in der Liste 1).
    var onColumnsChange: (Int) -> Void = { _ in }

    /// Nur Hover-Verstärkung der Kacheln (siehe oben) — kein Selektionszustand.
    @State private var hoveredID: UUID?

    var body: some View {
        GeometryReader { geo in
            let metrics = metrics(for: geo.size)
            ZStack {
                // Scrim: Terminal scheint angedeutet durch; Klick daneben = Abbruch.
                AgentTheme.background.opacity(0.62)
                    .contentShape(Rectangle())
                    .onTapGesture { onCancel() }
                card(metrics: metrics)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear { onColumnsChange(metrics.columns) }
            .onChange(of: metrics.columns) { _, columns in
                onColumnsChange(columns)
            }
        }
        .transition(.opacity)
    }

    private func metrics(for size: CGSize) -> TabSwitcherGridMetrics {
        switch presentation {
        case .list:
            return TabSwitcherListLayout.metrics(count: sessions.count, availableSize: size)
        case .grid:
            return TabSwitcherGridLayout.metrics(count: sessions.count, availableSize: size)
        }
    }

    private func card(metrics: TabSwitcherGridMetrics) -> some View {
        VStack(spacing: 10) {
            tiles(metrics: metrics)
            footer
        }
        .padding(16)
        .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(AgentTheme.borderStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.30), radius: 26, y: 10)
        .padding(24)
        .fixedSize()
        // Klicks auf die Karten-Fläche (zwischen den Zellen) dürfen nicht zum
        // Scrim durchfallen und den Switcher abbrechen.
        .onTapGesture {}
    }

    // MARK: - Kacheln (Liste oder Grid)

    private func tiles(metrics: TabSwitcherGridMetrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: metrics.needsScroll) {
                // Dauer-Anzeigen ticken nur hier, solange das Overlay offen
                // ist — nie in Sidebar oder Tabs (Plan, Performance-Regeln).
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    switch presentation {
                    case .list:
                        LazyVStack(spacing: TabSwitcherListLayout.spacing) {
                            ForEach(sessions) { session in
                                tileButton(for: session, now: context.date, arrangement: .row)
                                    .frame(height: TabSwitcherListLayout.rowHeight)
                                    .id(session.id)
                            }
                        }
                    case .grid:
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.fixed(TabSwitcherGridLayout.cardWidth), spacing: TabSwitcherGridLayout.spacing),
                                count: max(1, metrics.columns)
                            ),
                            spacing: TabSwitcherGridLayout.spacing
                        ) {
                            ForEach(sessions) { session in
                                tileButton(for: session, now: context.date, arrangement: .card)
                                    .frame(
                                        width: TabSwitcherGridLayout.cardWidth,
                                        height: TabSwitcherGridLayout.cardHeight
                                    )
                                    .id(session.id)
                            }
                        }
                    }
                }
            }
            .frame(width: metrics.gridWidth, height: metrics.gridHeight)
            .onChange(of: highlightedID) { _, id in
                guard metrics.needsScroll, let id else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: nil)
                }
            }
            .onAppear {
                if metrics.needsScroll, let highlightedID {
                    proxy.scrollTo(highlightedID, anchor: .center)
                }
            }
        }
    }

    /// Fußzeile: Tab-Anzahl + Bedien-Hinweis, dauerhaft sichtbar.
    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(sessions.count) Tabs")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(AgentTheme.textSecondary)
            Spacer(minLength: 12)
            Text(footerHint)
                .font(.system(size: 10))
                .foregroundStyle(AgentTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    private var footerHint: String {
        switch presentation {
        case .list:
            return "⌃Tab weiter · ⇧ rückwärts · ↑↓ navigieren · Loslassen wechselt · Esc bricht ab"
        case .grid:
            return "⌃Tab weiter · ⇧ rückwärts · ←→↑↓ navigieren · Loslassen wechselt · Esc bricht ab"
        }
    }

    // MARK: - Einzelkachel

    /// Baut das Kachel-Modell aus O(1)-Lookups je Session (kein Scan).
    private func tileButton(
        for session: AgentChatSession,
        now: Date,
        arrangement: TabSwitcherTile.Arrangement
    ) -> some View {
        let model = TabSwitcherTileModel(
            title: session.title,
            status: statusStore.status(for: session.id),
            activity: activityStore.activity(for: session.id),
            statusSince: activityStore.statusSince(for: session.id),
            lastActivityAt: session.lastActivityAt,
            now: now
        )
        return Button {
            onCommit(session.id)
        } label: {
            TabSwitcherTile(
                model: model,
                detail: .full,
                arrangement: arrangement,
                isHighlighted: session.id == highlightedID,
                isCurrent: session.id == currentID,
                isHovered: session.id == hoveredID
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredID = hovering ? session.id : (hoveredID == session.id ? nil : hoveredID)
        }
    }
}
