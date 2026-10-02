import SwiftUI

/// Ctrl+Tab-Umschalter in Situation B (Plan
/// `docs/plans/tab-switcher-workspace.md`, Slice S4): Ein Chat des
/// referenzierten Workspace ist maximiert, das Grid verborgen. Statt einer
/// Liste zeigt der Switcher das Grid als **Mini-Map** — dieselben Slots an
/// denselben Stellen, damit das räumliche Gedächtnis („oben rechts") trägt.
///
/// - Geometrie: ausschließlich `TabSwitcherMiniMapGeometry` (Rechtecke aus
///   denselben Bausteinen wie der Grid-Renderer, Größe aus dem
///   Content-Bereich, Detailstufe aus der Kachelgröße) — keine eigene Tabelle.
/// - Kacheln: `TabSwitcherTile` (`.card`). Die maximierte Kachel trägt das
///   „Hier"-Zeichen (`currentID`).
/// - Leere Slots und Slots außerhalb des Umfangs (Tab in einem anderen
///   Fenster, archiviert) sind zurückhaltende Platzhalter und nicht anwählbar.
///
/// Interaktion wie im `AgentTabSwitcherOverlay`: Tastatur komplett über die
/// NSEvent-Monitore in `AgentChatsView+Shortcuts` (Pfeile hier räumlich über
/// `TabSwitcherMiniMapGeometry.spatialTarget`), Klick auf eine Kachel =
/// sofortiger Commit, Klick auf den Scrim = Abbruch, Hover nur visuell.
///
/// Performance: Lookups nur über die ≤ 9 Umfangs-Sessions (Dictionary je
/// Rebuild), kein Scan über alle Sessions, kein I/O, kein `.contextMenu`.
/// Beide Stores werden NUR hier beobachtet (die View lebt nur während des
/// Umschaltens); die Dauer tickt per `TimelineView` nur, solange sie offen ist.
struct AgentTabSwitcherMiniMap: View {
    /// Workspace, den das Fenster referenziert — Snapshot aus dem
    /// Key-Event-Pfad (`refreshTabSwitcherScope`).
    let workspace: AgentGridWorkspace
    /// Ziele des Durchlaufs in Slot-Reihenfolge (`TabSwitcherScope.workspaceMap`).
    let sessions: [AgentChatSession]
    let highlightedID: UUID?
    /// Der maximierte Chat — trägt das „Hier"-Zeichen.
    let currentID: UUID?
    @ObservedObject var statusStore: AgentSessionRuntimeStatusStore
    @ObservedObject var activityStore: AgentSessionActivityStore
    let onCommit: (UUID) -> Void
    let onCancel: () -> Void

    @State private var hoveredID: UUID?

    /// Chrome um die Map: Außen-Padding (24) + Karten-Padding (16) je Seite,
    /// vertikal zusätzlich Titel- und Footer-Zeile samt Abständen.
    private static let chrome = CGSize(width: 80, height: 134)
    /// Abstand zwischen zwei Kacheln (halber Wert je Kachelseite).
    private static let tileGap: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            // Der Overlay-Rahmen IST der Content-Bereich der Einzelansicht —
            // genau dort stünde das Grid, deshalb auch die Bezugsgröße der Spuren.
            let mapSize = TabSwitcherMiniMapGeometry.fittedMapSize(
                contentSize: geo.size, chrome: Self.chrome
            )
            ZStack {
                // Scrim: Terminal scheint angedeutet durch; Klick daneben = Abbruch.
                AgentTheme.background.opacity(0.62)
                    .contentShape(Rectangle())
                    .onTapGesture { onCancel() }
                card(gridSize: geo.size, mapSize: mapSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .transition(.opacity)
    }

    private func card(gridSize: CGSize, mapSize: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            map(gridSize: gridSize, mapSize: mapSize)
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
        // Klicks auf die Karten-Fläche (Titel, Lücken, Platzhalter) dürfen
        // nicht zum Scrim durchfallen und den Switcher abbrechen.
        .onTapGesture {}
    }

    // MARK: - Titel und Footer

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(hex: workspace.colorHex))
                .frame(width: 8, height: 8)
            Text("Workspace „\(workspace.name)“")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AgentTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(height: 20)
    }

    private var footer: some View {
        Text("⌃Tab weiter · ⇧ zurück · Pfeile räumlich · Esc")
            .font(.system(size: 10))
            .foregroundStyle(AgentTheme.textTertiary)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: 14)
    }

    // MARK: - Map

    private func map(gridSize: CGSize, mapSize: CGSize) -> some View {
        let rects = TabSwitcherMiniMapGeometry.slotRects(
            for: workspace, gridSize: gridSize, targetSize: mapSize
        )
        // Lookup über die Umfangs-Sessions (≤ 9), nie über alle Sessions.
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let inset = Self.tileGap / 2
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            ZStack(alignment: .topLeading) {
                ForEach(rects, id: \.slot) { slotRect in
                    let frame = slotRect.rect.insetBy(dx: inset, dy: inset)
                    let session = workspace.slots.indices.contains(slotRect.slot)
                        ? workspace.slots[slotRect.slot].flatMap { byID[$0] }
                        : nil
                    Group {
                        if let session {
                            tileButton(
                                for: session,
                                detail: TabSwitcherMiniMapGeometry.tileDetail(for: frame.size),
                                now: context.date
                            )
                        } else {
                            placeholder(isEmptySlot: workspace.slots.indices.contains(slotRect.slot)
                                && workspace.slots[slotRect.slot] == nil)
                        }
                    }
                    .frame(width: max(0, frame.width), height: max(0, frame.height))
                    .offset(x: frame.minX, y: frame.minY)
                }
            }
            .frame(width: mapSize.width, height: mapSize.height, alignment: .topLeading)
        }
    }

    /// Leerer Slot bzw. Slot ohne anwählbaren Chat — sichtbar (das Layout
    /// bleibt lesbar), aber ohne Aktion.
    private func placeholder(isEmptySlot: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(
                AgentTheme.textTertiary.opacity(0.28),
                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
            )
            .overlay {
                if !isEmptySlot {
                    Image(systemName: "macwindow")
                        .font(.system(size: 11))
                        .foregroundStyle(AgentTheme.textTertiary.opacity(0.6))
                        .help("Chat ist hier nicht anwählbar (z. B. Tab in einem anderen Fenster)")
                }
            }
            .accessibilityLabel(isEmptySlot ? "Leerer Slot" : "Chat nicht anwählbar")
    }

    /// Baut das Kachel-Modell aus O(1)-Lookups je Session (kein Scan).
    private func tileButton(
        for session: AgentChatSession,
        detail: TabSwitcherTileDetail,
        now: Date
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
                detail: detail,
                arrangement: .card,
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
