import SwiftUI

/// Ctrl+Tab-Umschalter: Overlay über dem Terminal-Content der Agent-Chats.
/// Liegt bewusst NUR über dem Content-Bereich (Anker: die Session-Group in
/// `mainWorkspace`) — Sidebar und Tab-Strip bleiben sichtbar und bedienbar.
///
/// Darstellung: Karten-Grid mit Umbruch statt einzeiliger Zellen-Reihe — der
/// Switcher ist eine Übersicht, also müssen ALLE offenen Tabs lesbar sein.
/// Jede Karte trägt die Kerninfos direkt (Status, Icon, Titel, Projekt +
/// Branch, Summary-Headline); ein separater Detailbereich entfällt. Die
/// Grid-Mathematik (Spalten/Reihen/Scroll) lebt pur und getestet in
/// `TabSwitcherGridLayout`. Erst wenn die Reihen den verfügbaren Platz
/// sprengen, scrollt das Grid vertikal und hält das Highlight in Sicht.
///
/// Interaktion:
/// - Tastatur (Ctrl+Tab / Ctrl+Shift+Tab / ←→↑↓ / Esc / Return) läuft komplett
///   über die NSEvent-Monitore in `AgentChatsView+Shortcuts` — diese View
///   rendert nur den Zustand (`highlightedID`) und meldet die aktuelle
///   Spaltenzahl für die ↑/↓-Schrittweite zurück (`onColumnsChange`).
/// - Maus: Klick auf eine Karte = sofortiger Commit (auch bei gehaltenem
///   Ctrl), Klick auf den Scrim = Abbruch. Hover verstärkt eine Karte nur
///   visuell und verschiebt NIE das Keyboard-Highlight — sonst kämpfen
///   Mausposition und Tab-Taste um das Highlight und ein Ctrl-Loslassen
///   committet überraschend den gehoverten statt den ertabbten Chat.
///
/// Performance: rein speicherbasiert — Status ist ein Dictionary-Lookup,
/// die Kontext-Zeile kommt aus dem bereits persistierten
/// `session.summary?.headline`. Kein Transcript-Read, kein Terminal-Snapshot.
/// Der Store wird als `@ObservedObject` beobachtet; das invalidiert nur diese
/// Overlay-View (sie existiert nur während des Umschaltens), nicht den
/// AgentChatsView-Body — die P4-Regel „Body liest `.statuses` nie direkt"
/// bleibt gewahrt.
struct AgentTabSwitcherOverlay: View {
    /// Offene Tabs in Anzeige-Reihenfolge (`headerTabs`).
    let sessions: [AgentChatSession]
    let highlightedID: UUID?
    let projectsByID: [UUID: AgentProject]
    @ObservedObject var statusStore: AgentSessionRuntimeStatusStore
    let onCommit: (UUID) -> Void
    let onCancel: () -> Void
    /// Meldet die aktuell gerenderte Spaltenzahl an die AgentChatsView —
    /// die ↑/↓-Navigation in `+Shortcuts` springt damit exakt eine
    /// Grid-Reihe (Schrittweite = Spalten).
    var onColumnsChange: (Int) -> Void = { _ in }

    /// Nur Hover-Verstärkung der Karten (siehe oben) — kein Selektionszustand.
    @State private var hoveredID: UUID?

    var body: some View {
        GeometryReader { geo in
            let metrics = TabSwitcherGridLayout.metrics(count: sessions.count, availableSize: geo.size)
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

    private func card(metrics: TabSwitcherGridMetrics) -> some View {
        VStack(spacing: 10) {
            grid(metrics: metrics)
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

    // MARK: - Karten-Grid

    private func grid(metrics: TabSwitcherGridMetrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: metrics.needsScroll) {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(TabSwitcherGridLayout.cardWidth), spacing: TabSwitcherGridLayout.spacing),
                        count: max(1, metrics.columns)
                    ),
                    spacing: TabSwitcherGridLayout.spacing
                ) {
                    ForEach(sessions) { session in
                        cardCell(for: session)
                            .id(session.id)
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
            Text("⌃Tab weiter · ⇧ rückwärts · ←→↑↓ navigieren · Loslassen wechselt · Esc bricht ab")
                .font(.system(size: 10))
                .foregroundStyle(AgentTheme.textTertiary)
                .lineLimit(1)
        }
    }

    // MARK: - Einzelkarte

    private func cardCell(for session: AgentChatSession) -> some View {
        let isHighlighted = session.id == highlightedID
        let isHovered = session.id == hoveredID
        let project = projectsByID[session.projectID]

        return Button {
            onCommit(session.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    // Status dauerhaft auf JEDER Karte sichtbar (kein Hover-only-UI).
                    AgentStatusIndicator(status: statusStore.status(for: session.id))
                    AgentSessionIcon(
                        session: session,
                        size: 11,
                        tint: isHighlighted ? AgentTheme.textPrimary : AgentTheme.textSecondary
                    )
                    kindBadges(session)
                    Spacer(minLength: 6)
                    Text(SidebarRelativeTime.short(session.lastActivityAt))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(AgentTheme.textTertiary)
                }

                Text(session.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isHighlighted ? AgentTheme.textPrimary : AgentTheme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    // 2 Zeilen reservieren, damit alle Karten gleich hoch wirken.
                    .frame(minHeight: 32, alignment: .topLeading)

                projectRow(project)
                summaryRow(session)
            }
            .padding(10)
            .frame(
                width: TabSwitcherGridLayout.cardWidth,
                height: TabSwitcherGridLayout.cardHeight,
                alignment: .topLeading
            )
            .background(
                isHighlighted
                    ? AnyShapeStyle(AgentTheme.selectionStrong)
                    : AnyShapeStyle(AgentTheme.control.opacity(isHovered ? 0.9 : 0.45)),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isHighlighted ? AgentTheme.accent.opacity(0.85) : AgentTheme.border,
                        lineWidth: isHighlighted ? 1.5 : 0.5
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredID = hovering ? session.id : (hoveredID == session.id ? nil : hoveredID)
        }
    }

    /// Sub-Kind-Badges (BG / VIEW / TERM) — gleiche Semantik wie im Header.
    @ViewBuilder
    private func kindBadges(_ session: AgentChatSession) -> some View {
        if session.isBackgroundChat {
            kindBadge("BG", color: .indigo)
        } else if session.isAgentView {
            kindBadge("VIEW", color: .orange)
        } else if session.isTerminal {
            kindBadge("TERM", color: .teal)
        }
    }

    /// Projekt · Branch — gleiche Datenquellen wie `secondaryProjectRow`
    /// in der AgentChatsView, nur mit reservierter Höhe (kein Springen).
    @ViewBuilder
    private func projectRow(_ project: AgentProject?) -> some View {
        HStack(spacing: 5) {
            if let project {
                Image(systemName: "folder")
                    .font(.system(size: 8.5))
                    .foregroundStyle(AgentTheme.textTertiary)
                Text(project.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .lineLimit(1)
                if let branch = project.lastBranch, !branch.isEmpty {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8.5))
                        .foregroundStyle(AgentTheme.textTertiary)
                    Text(branch)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(AgentTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 13)
    }

    /// Kontext-Zeile: die persistierte Summary-Headline („worum ging's").
    /// Bewusst KEIN Live-Transcript-Read — null I/O pro Highlight-Wechsel.
    @ViewBuilder
    private func summaryRow(_ session: AgentChatSession) -> some View {
        Group {
            if let headline = session.summary?.headline, !headline.isEmpty {
                Text(headline)
                    .font(.system(size: 10))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func kindBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .tracking(0.04)
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3).stroke(color.opacity(0.30), lineWidth: 0.5)
            )
            .fixedSize()
    }
}
