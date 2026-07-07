import SwiftUI

/// Ctrl+Tab-Umschalter: Overlay über dem Terminal-Content der Agent-Chats.
/// Liegt bewusst NUR über dem Content-Bereich (Anker: die Session-Group in
/// `mainWorkspace`) — Sidebar und Tab-Strip bleiben sichtbar und bedienbar.
///
/// Interaktion:
/// - Tastatur (Ctrl+Tab / Ctrl+Shift+Tab / Esc / Return) läuft komplett über
///   die NSEvent-Monitore in `AgentChatsView+Shortcuts` — diese View rendert
///   nur den Zustand (`highlightedID`).
/// - Maus: Klick auf eine Zelle = sofortiger Commit (auch bei gehaltenem
///   Ctrl), Klick auf den Scrim = Abbruch. Hover verstärkt eine Zelle nur
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

    /// Nur Hover-Verstärkung der Zellen (siehe oben) — kein Selektionszustand.
    @State private var hoveredID: UUID?

    private var highlighted: AgentChatSession? {
        sessions.first { $0.id == highlightedID }
    }

    var body: some View {
        ZStack {
            // Scrim: Terminal scheint angedeutet durch; Klick daneben = Abbruch.
            AgentTheme.background.opacity(0.62)
                .contentShape(Rectangle())
                .onTapGesture { onCancel() }
            card
        }
        .transition(.opacity)
    }

    private var card: some View {
        VStack(spacing: 12) {
            cellRow
            Divider().overlay(AgentTheme.border)
            detailArea
        }
        .padding(14)
        .frame(maxWidth: 680)
        .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(AgentTheme.borderStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.30), radius: 26, y: 10)
        .padding(24)
        // Klicks auf die Karten-Fläche (zwischen den Zellen) dürfen nicht zum
        // Scrim durchfallen und den Switcher abbrechen.
        .onTapGesture {}
    }

    // MARK: - Zellenreihe

    /// Horizontale Reihe kompakter Tab-Zellen. Bei vielen Tabs scrollt die
    /// Reihe und zentriert sich auf das Highlight — die Karte wird nie
    /// breiter als `maxWidth`.
    private var cellRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sessions) { session in
                        cell(for: session)
                            .id(session.id)
                    }
                }
                .padding(2)
            }
            .onChange(of: highlightedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onAppear {
                if let highlightedID {
                    proxy.scrollTo(highlightedID, anchor: .center)
                }
            }
        }
    }

    private func cell(for session: AgentChatSession) -> some View {
        let isHighlighted = session.id == highlightedID
        let isHovered = session.id == hoveredID
        return Button {
            onCommit(session.id)
        } label: {
            HStack(spacing: 6) {
                // Status dauerhaft auf JEDER Zelle sichtbar (kein Hover-only-UI).
                AgentStatusIndicator(status: statusStore.status(for: session.id))
                ProviderIcon(
                    provider: session.provider,
                    size: 11,
                    tint: isHighlighted ? AgentTheme.textPrimary : AgentTheme.textSecondary
                )
                Text(session.title)
                    .font(.system(size: 11, weight: isHighlighted ? .semibold : .regular))
                    .foregroundStyle(isHighlighted ? AgentTheme.textPrimary : AgentTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 140)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isHighlighted
                    ? AnyShapeStyle(AgentTheme.selectionStrong)
                    : AnyShapeStyle(AgentTheme.control.opacity(isHovered ? 0.9 : 0.45)),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isHighlighted ? AgentTheme.accent.opacity(0.8) : AgentTheme.border,
                        lineWidth: isHighlighted ? 1.2 : 0.5
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredID = hovering ? session.id : (hoveredID == session.id ? nil : hoveredID)
        }
    }

    // MARK: - Detailbereich

    /// Kerninfos des hervorgehobenen Chats. Die Zeilen reservieren ihre Höhe
    /// auch ohne Inhalt (Branch fehlt, keine Summary), damit die Karte beim
    /// Durchtabben nicht springt.
    @ViewBuilder
    private var detailArea: some View {
        if let session = highlighted {
            let project = projectsByID[session.projectID]
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    AgentStatusIndicator(status: statusStore.status(for: session.id))
                    Text(session.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AgentTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if session.isBackgroundChat {
                        kindBadge("BG", color: .indigo)
                        if let shortID = session.backgroundShortID, !shortID.isEmpty {
                            Text(shortID)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(AgentTheme.textTertiary)
                        }
                    } else if session.isAgentView {
                        kindBadge("VIEW", color: .orange)
                    }
                    Spacer(minLength: 12)
                    Text(SidebarRelativeTime.short(session.lastActivityAt))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(AgentTheme.textTertiary)
                }
                projectRow(project)
                summaryRow(session)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Projekt · Branch · Pfad — gleiche Datenquellen wie `secondaryProjectRow`
    /// in der AgentChatsView, nur mit reservierter Höhe.
    @ViewBuilder
    private func projectRow(_ project: AgentProject?) -> some View {
        if let project {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 9))
                    .foregroundStyle(AgentTheme.textTertiary)
                Text(project.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .lineLimit(1)
                if let branch = project.lastBranch, !branch.isEmpty {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                        .foregroundStyle(AgentTheme.textTertiary)
                    Text(branch)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(AgentTheme.textTertiary)
                        .lineLimit(1)
                }
                Text("·")
                    .font(.system(size: 10))
                    .foregroundStyle(AgentTheme.textTertiary)
                Text(project.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .frame(height: 14)
        } else {
            Color.clear.frame(height: 14)
        }
    }

    /// Kontext-Zeile: die persistierte Summary-Headline („worum ging's").
    /// Bewusst KEIN Live-Transcript-Read — null I/O pro Highlight-Wechsel.
    @ViewBuilder
    private func summaryRow(_ session: AgentChatSession) -> some View {
        Group {
            if let headline = session.summary?.headline, !headline.isEmpty {
                Text(headline)
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .lineLimit(2)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .topLeading)
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
