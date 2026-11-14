import SwiftUI

// MARK: - Tab-Leiste: die Elemente im Streifen

/// Aus `AgentChatsView.swift` ausgelagert, ohne Änderung am Verhalten: die
/// Elemente des Tab-Streifens (einzelne Tabs und Workspace-Gruppen) samt
/// Drag-Quelle, Kontextmenü und Messung für die Einfüge-Linie. Reihenfolge,
/// Auswahl und Umfang des Umschalters bleiben in der puren Tab-Logik.
extension AgentChatsView {
    @ViewBuilder
    var tabStripItemsContent: some View {
        // zIndex hebt das Element mit dem aktiven Tab an, damit dessen
        // Chrome-Füße (7pt über die eigene Breite hinaus) über den
        // Nachbar-Tabs statt darunter gezeichnet werden.
        ForEach(Array(tabGroupingItems.enumerated()), id: \.offset) { _, item in
            switch item {
            case .single(let sessionID):
                if let session = headerTabs.first(where: { $0.id == sessionID }) {
                    chromeTab(session, groupColor: nil)
                        .zIndex(sessionID == selectedSession?.id ? 1 : 0)
                }
            case .group(let key, let sessionIDs):
                chromeTabGroup(key: key, sessionIDs: sessionIDs)
                    .zIndex((selectedSessionID.map(sessionIDs.contains) ?? false) ? 1 : 0)
            }
        }
    }

    func visibleTabIDs(
        in sessionIDs: [UUID],
        collapsed: Bool
    ) -> [UUID] {
        guard collapsed else { return sessionIDs }
        guard let selectedSessionID, sessionIDs.contains(selectedSessionID) else { return [] }
        return [selectedSessionID]
    }

    func chromeTabGroup(
        key: AgentTabGroupingKey,
        sessionIDs: [UUID]
    ) -> some View {
        let metadata = tabGroupMetadata(for: key)
        let color = Color(hex: metadata.colorHex)
        let isCollapsed = collapsedTabGroups.contains(key)
        let isActive = selectedSessionID.map(sessionIDs.contains) ?? false
        let visibleIDs = visibleTabIDs(in: sessionIDs, collapsed: isCollapsed)

        return HStack(alignment: .bottom, spacing: 0) {
            ChatTabGroupLabel(
                title: metadata.title,
                count: sessionIDs.count,
                colorHex: metadata.colorHex,
                isCollapsed: isCollapsed,
                isActive: isActive,
                onToggle: {
                    if isCollapsed {
                        collapsedTabGroups.remove(key)
                    } else {
                        collapsedTabGroups.insert(key)
                        // Eingeklappte Mitglieder verschwinden aus der Leiste.
                        // Blieben sie ausgewählt, würden Bulk-Aktionen („N Tabs
                        // schließen/archivieren") Chats treffen, die der User
                        // nicht mehr sieht — bei Terminal-Sessions unwiderruflich.
                        let hidden = Set(sessionIDs)
                            .subtracting(visibleTabIDs(in: sessionIDs, collapsed: true))
                        if !hidden.isEmpty { multiSelection.subtract(hidden) }
                    }
                }
            )
            // Das Label gehört geometrisch zum ersten Tab. Der Preference-Key
            // vereinigt beide Frames, sodass „vor erstem Gruppenmitglied" die
            // Einfügelinie links VOR dem Label zeichnet.
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: TabFramePreferenceKey.self,
                        value: sessionIDs.first.map {
                            [$0: geo.frame(in: .named(Self.tabStripContentSpace))]
                        } ?? [:]
                    )
                }
            )
            // Der Chip ist der GRIFF der ganzen Gruppe — auf- wie zugeklappt.
            .draggable(DraggableSession(
                sessionID: sessionIDs.first ?? UUID(),
                sourceProjectID: headerTabs.first { $0.id == sessionIDs.first }?.projectID ?? UUID(),
                sourceWindowID: windowID,
                groupMemberIDs: sessionIDs
            )) {
                TabDragPreview(
                    title: metadata.title,
                    extraCount: max(0, sessionIDs.count - 1)
                )
            }

            ForEach(visibleIDs, id: \.self) { sessionID in
                if let session = headerTabs.first(where: { $0.id == sessionID }) {
                    chromeTab(session, groupColor: color)
                        .zIndex(sessionID == selectedSessionID ? 1 : 0)
                }
            }
        }
        // Eingeklappt ist der Cluster EIN Drop-Slot — dafür muss sein
        // gesamter Frame (Chip + ggf. sichtbarer aktiver Tab) unter der
        // Leading-ID liegen, sonst endet die Einfügelinie am Chip.
        .background {
            if isCollapsed {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: TabFramePreferenceKey.self,
                        value: sessionIDs.first.map {
                            [$0: geo.frame(in: .named(Self.tabStripContentSpace))]
                        } ?? [:]
                    )
                }
            }
        }
        // 2pt-Gruppenlinie am Boden des Clusters (Chip → letztes Mitglied).
        // Sie liegt HINTER den Tabs: der aktive Tab deckt sie mit seiner
        // Header-Fläche ab, und seine Fußbögen führen sie außen um ihn herum
        // — ein durchgehender Farbzug wie bei Chromes Tab-Gruppen.
        .background(alignment: .bottom) {
            UnevenRoundedRectangle(
                topLeadingRadius: 2,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 2
            )
            .fill(color)
            .frame(height: 2)
            .padding(.leading, 2)
        }
    }

    /// Einzelner Tab inklusive aller bestehenden Browser-Interaktionen. Das
    /// Rendering wird von `projectChatStrip` nur noch in Herkunfts-Cluster
    /// einsortiert; Drag, Kontextmenü, Mittelklick und Frame-Messung bleiben
    /// weiterhin pro Session-ID erhalten.
    func chromeTab(
        _ session: AgentChatSession,
        groupColor: Color?
    ) -> some View {
        ChatTabButton(
            session: session,
            project: workspace.projects.first { $0.id == session.projectID },
            isSelected: session.id == selectedSession?.id,
            isMultiSelected: multiSelection.contains(session.id),
            statusStore: runtimeStatusStore,
            groupColor: groupColor,
            onSelect: {
                handleTabClick(session.id)
            },
            onClose: {
                closeTabByUser(session)
            }
        )
        // Mittelklick (Mausrad) schließt den Tab — wie im Browser.
        .onMiddleClick { closeTabByUser(session) }
        .draggable(DraggableSession(
            sessionID: session.id,
            sourceProjectID: session.projectID,
            sourceWindowID: windowID
        )) {
            TabDragPreview(
                title: session.title,
                extraCount: max(0, tabDragGroup(for: session).count - 1)
            )
        }
        .contextMenu {
            sessionContextMenu(session, context: .tab)
        }
        // Tab-Frame im Inhalts-Space messen → Einfüge-Linie.
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: TabFramePreferenceKey.self,
                    value: [session.id: geo.frame(in: .named(Self.tabStripContentSpace))]
                )
            }
        )
        .id(session.id)
    }
}
