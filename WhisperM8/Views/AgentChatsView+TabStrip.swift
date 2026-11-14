import SwiftUI

// MARK: - Tab-Leiste: die Elemente im Streifen und der Streifen selbst

/// Aus `AgentChatsView.swift` ausgelagert, ohne Änderung am Verhalten: die
/// Elemente des Tab-Streifens (einzelne Tabs und Workspace-Gruppen) samt
/// Drag-Quelle, Kontextmenü und Messung für die Einfüge-Linie, und der
/// Streifen selbst (`projectChatStrip`) mit Titelzone, Breitenmessung und
/// Drop-Ziel. Reihenfolge, Auswahl und Umfang des Umschalters bleiben in der
/// puren Tab-Logik.
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

    // MARK: - Der Streifen selbst

    var projectChatStrip: some View {
        VStack(spacing: 0) {
            // Tabs sitzen in der Titelzone, browserähnlich neben den Ampel-
            // Buttons. Das Fenster zieht dort nur auf ausgewiesenen
            // Griffflächen (`windowDragArea`) — über Tabs und Knöpfen ist
            // `isMovable` aus (`TitleBandPointerTracker`), sonst zöge ein Klick
            // mit etwas Mausbewegung das Fenster, statt anzukommen.
            HStack(spacing: 5) {
                if !isSidebarVisible {
                    // Platz für die Ampel-Buttons, wenn die Sidebar aus ist.
                    Spacer().frame(width: 70)
                        .windowDragArea(depth: TabStripBand.height)
                }

                TitlebarIconButton(systemImage: "sidebar.left", help: isSidebarVisible ? String(localized: "Hide sidebar") : String(localized: "Show sidebar"), isActive: isSidebarVisible) {
                    isSidebarVisible.toggle()
                }
                TicketsModeButton(windowStore: windowStore, windowID: windowID)

                if !headerTabs.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            // 6pt Luft ZWISCHEN Gruppen/Einzeltabs (0pt innen)
                            // trägt die Gruppierung räumlich; das horizontale
                            // Padding gibt den Chrome-Füßen des aktiven Tabs
                            // an den Strip-Rändern Platz (sonst clippt der
                            // ScrollView die 7pt-Ausstellung).
                            HStack(alignment: .bottom, spacing: 6) {
                                tabStripItemsContent
                            }
                            .padding(.horizontal, 8)
                            // Volle Zeilenhöhe, unten verankert: die Tabs
                            // MÜSSEN bündig auf der Zeilen-Unterkante stehen,
                            // sonst bleibt ein 1pt-Leistenstreifen zwischen
                            // aktivem Tab und Chat-Header sichtbar.
                            .frame(height: 34, alignment: .bottom)
                            .coordinateSpace(.named(Self.tabStripContentSpace))
                            .onPreferenceChange(TabFramePreferenceKey.self) { tabFrames = $0 }
                            // Stale IDs aus der Multi-Auswahl entfernen, wenn sich die offenen Tabs ändern.
                            .onChange(of: headerTabs.map(\.id)) { _, _ in
                                // Gegen ALLE Sessions prunen (nicht nur offene Tabs) — die
                                // Multi-Auswahl gilt auch für Sidebar-Sessions ohne offenen Tab.
                                multiSelection.formIntersection(Set(workspace.sessions.map(\.id)))
                            }
                            // Einfüge-Linie — steht immer auf einer ERLAUBTEN
                            // Slot-Grenze, weil der Delegate den rohen Index
                            // vorher dorthin schnappt. Eingeklappte Gruppen
                            // bleiben dabei eingeklappt: sie sind ein Slot.
                            .overlay(alignment: .leading) {
                                if let index = tabInsertionIndex,
                                   let x = TabReorderGeometry.insertionX(
                                    forIndex: index,
                                    orderedIDs: tabSlotOrderIDs,
                                    frames: tabFrames,
                                    spacing: 0
                                   ) {
                                    TabInsertionIndicator()
                                        .offset(x: x - 1.25)
                                        .allowsHitTesting(false)
                                }
                            }
                            .animation(.easeOut(duration: 0.1), value: tabInsertionIndex)
                            .background(WindowDragExclusionView())
                            // Reorder/Move + Cross-Window: EIN DropDelegate für die
                            // ganze Leiste → kontinuierliche Einfüge-Position (Linie)
                            // und Move-Semantik (kein Copy-„+"). Cross-Window/Sidebar-
                            // Open laufen weiter über windowStore.moveTab in dropTab.
                            .onDrop(of: [.agentChatSession], delegate: TabReorderDropDelegate(
                                orderedIDs: tabSlotOrderIDs,
                                frames: tabFrames,
                                insertionIndex: $tabInsertionIndex,
                                droppedSession: $tabDropSession,
                                dragGeneration: $tabDragGeneration,
                                snapIndex: { dropped, rawIndex in
                                    snappedTabDropIndex(for: dropped, rawIndex: rawIndex)
                                },
                                onMove: { dropped, slotIndex in
                                    let source = dropped.sourceWindowID ?? windowID
                                    let group = draggedTabIDs(for: dropped)
                                    let movingIDs = Set(group)
                                    let adjustedBeforeID = tabDropTargetID(
                                        atSlotIndex: slotIndex,
                                        moving: movingIDs
                                    )
                                    if source == windowID {
                                        // Die sichtbare Gruppen-Reihenfolge wird zur neuen
                                        // manuellen Reihenfolge. Fremde Tabs schnappen an die
                                        // Cluster-Grenze, statt eine Gruppe optisch zu teilen.
                                        let currentVisualOrder = visualTabOrderIDs
                                        let missingIDs = group.filter {
                                            !currentVisualOrder.contains($0)
                                        }
                                        let reorderBase = currentVisualOrder + missingIDs
                                        let newOrder = TabOrderReorder.newOrder(
                                            reorderBase,
                                            moving: movingIDs,
                                            before: adjustedBeforeID
                                        )
                                        // Ein effektiver No-op darf die separat
                                        // persistierte manuelle Reihenfolge nicht
                                        // bloß auf die Gruppenansicht normalisieren.
                                        if newOrder != currentVisualOrder {
                                            windowStore.setOpenTabIDs(newOrder, in: windowID)
                                            if !missingIDs.isEmpty {
                                                selectedSessionID = dropped.sessionID
                                            }
                                        }
                                    } else {
                                        // Cross-window: ganze Gruppe in ihrer sichtbaren
                                        // Reihenfolge hierher holen.
                                        for id in group {
                                            windowStore.moveTab(
                                                id,
                                                from: source,
                                                to: windowID,
                                                before: adjustedBeforeID
                                            )
                                        }
                                        windowStore.setMultiSelection([], in: source)
                                        // Auch die ZIEL-Auswahl räumen: `moveTab`
                                        // aktiviert den zuletzt geholten Tab, eine
                                        // stehengebliebene Auswahl enthielte den
                                        // aktiven Anker nicht mehr (Invariante aus
                                        // TabSelectionResolver).
                                        multiSelection = []
                                    }
                                    // Einzel-Drag (kein Gruppen-Tab) verwirft die Auswahl (Chrome/Finder).
                                    if group.count <= 1 { multiSelection = [] }
                                }
                            ))
                            // Gesamtbreite des Inhalts → Überlauf-Erkennung fürs Chevron.
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(key: TabStripContentWidthKey.self, value: geo.size.width)
                                }
                            )
                        }
                        .background {
                            // Unsichtbare Shortcut-Anker: ⌘1–⌘9 springen auf
                            // Tab 1–9 der globalen Tab-Bar.
                            ForEach(Array(visualHeaderTabs.prefix(9).enumerated()), id: \.element.id) { index, session in
                                Button("") { selectedSessionID = session.id }
                                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                                    .frame(width: 0, height: 0)
                                    .opacity(0)
                                    .accessibilityHidden(true)
                            }
                        }
                        // Sichtbare Frame des Strips → Viewport-Breite (Überlauf)
                        // + X-Spanne (window-relativ) fürs Hit-Test-Gating des
                        // Mausrad-Monitors.
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: TabStripFrameKey.self,
                                    value: geo.frame(in: .named(Self.windowCoordinateSpaceName))
                                )
                            }
                        )
                        .onPreferenceChange(TabStripContentWidthKey.self) { stripContentWidth = $0 }
                        .onPreferenceChange(TabStripFrameKey.self) { frame in
                            stripFrameInWindow = frame
                            stripViewportWidth = frame.width
                        }
                        // Bei Tab-Wechsel (⌘⌥←/→, ⌘1–⌘9, Sidebar) den aktiven Tab
                        // in Sicht scrollen, falls die Bar überläuft. Hält außerdem
                        // den Mausrad-Anker an der Selektion, damit das Rad danach
                        // von dort weiterläuft.
                        .onChange(of: selectedSessionID) { _, id in
                            guard let id else { return }
                            stripWheelAnchorID = id
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                        // Mausrad-Scroll (siehe handleTabStripScroll): tab-weise
                        // horizontal scrollen (scrollTo auf eine nicht mehr
                        // vorhandene ID ist ein No-Op → robust gegen Tab-Close).
                        .onChange(of: stripWheelTick) { _, _ in
                            guard let id = stripWheelAnchorID else { return }
                            withAnimation(.easeInOut(duration: 0.12)) {
                                proxy.scrollTo(id, anchor: .leading)
                            }
                        }
                    }
                }

                TitlebarIconButton(
                    systemImage: "rectangle.stack",
                    help: tabGroupingEnabled ? String(localized: "Turn tab groups off") : String(localized: "Turn tab groups on"),
                    isActive: tabGroupingEnabled
                ) {
                    tabGroupingEnabled.toggle()
                }

                // Overflow-Menü: erscheint nur bei Tab-Überlauf (Fenstermodus).
                // Listet ALLE offenen Tabs; Klick selektiert → bestehender
                // onChange scrollt den Tab in Sicht. Im Fullscreen unsichtbar.
                if hasTabOverflow {
                    Menu {
                        ForEach(visualHeaderTabs) { session in
                            Button {
                                selectedSessionID = session.id
                            } label: {
                                if session.id == selectedSession?.id {
                                    Label(session.title, systemImage: "checkmark")
                                } else {
                                    Text(session.title)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(AgentTheme.textSecondary)
                            .frame(width: 22, height: 22)
                            .background(AgentTheme.control.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("All tabs")
                }

                Menu {
                    newChatMenuContent
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AgentTheme.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(AgentTheme.control.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(selectedProject == nil)
                .help("Create new chat")

                Spacer(minLength: 8)
                    .windowDragArea(depth: TabStripBand.height)

                // Branch-Badge entfernt — die Branch steht ohnehin schon in
                // der Sidebar-Projekt-Zeile und im Project-Inspector, und
                // visueller Clutter im Titlebar-Bereich kostet mehr als er
                // hier liefert.

                TitlebarIconButton(systemImage: "sidebar.right", help: isInspectorVisible ? String(localized: "Hide project context") : String(localized: "Show project context"), isActive: isInspectorVisible) {
                    isInspectorVisible.toggle()
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 6)
            // 34pt statt 30pt: die Tabs (28pt) brauchen wie im Mockup (30 in
            // 36) sichtbare Leisten-Luft ÜBER sich — sonst klebt der aktive
            // Tab samt Gruppen-Kontur direkt an der Fensteroberkante und der
            // „Tab hebt sich aus der Leiste"-Effekt geht verloren.
            .frame(height: 34, alignment: .bottom)
            // Chrome-Prinzip: die Leiste ist DUNKLER als der Header darunter;
            // keine Trennlinie — der aktive Tab (headerfarben) geht dadurch
            // nahtlos in den Chat-Header über.
            .background(AgentTheme.tabBar)

            // Im sichtbaren Grid ersetzt die Workspace-Zeile (Name + Belegung
            // + Kapazitäts-Picker) den Chat-Header — die Pane-Header tragen
            // die Session-Infos bereits, und der Picker verdeckt so keine
            // Pane mehr (vorher Overlay über der rechten oberen Pane).
            if isGridActive, let entity = activeGridWorkspaceEntity {
                gridWorkspaceStatusRow(entity: entity)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            } else {
                anchoredChatStatusRow
            }
        }
        .background(AgentTheme.header)
    }
}
