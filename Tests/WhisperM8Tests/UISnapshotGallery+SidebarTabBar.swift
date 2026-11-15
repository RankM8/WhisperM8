import SwiftUI
@testable import WhisperM8

/// Seitenleiste und Tab-Leiste nach WM8-80 (Seitenleiste A, Tabs 1, Kleinkram)
/// mit den Daten des Zwillings: Umschalter mit Zählern, Workspaces mit grauer
/// Slot-Marke und 26-pt-Zeilen, Projektgruppen mit Plus, Hinweis und
/// „N gestoppt“, darüber die schrumpfende Tab-Leiste mit dem einen Tab-Menü.
/// Aus den echten Bauteilen zusammengesetzt; nur Kopf und Rahmen der
/// Workspaces und die Knöpfe der Leiste sind nachgestellt.
extension UISnapshotGallery {
    @MainActor
    static func sidebarTabBarFixtures() -> [Fixture] {
        let store = AgentSessionRuntimeStatusStore()
        let wm8 = AgentProject(name: "whisperm8", path: "/tmp/whisperm8", color: "#3D6DF2",
                               lastBranch: "main", createdManually: true)
        let lm8 = AgentProject(name: "ListM8", path: "/tmp/ListM8", color: "#E8590C",
                               lastBranch: "develop", createdManually: true)
        let akq = AgentProject(name: "akquise-ai", path: "/tmp/akquise-ai", color: "#64748B",
                               lastBranch: "HB-AI-UI", createdManually: true)
        func chat(_ title: String, _ project: AgentProject, minutesAgo: Double = 1,
                  _ status: AgentSessionRuntimeStatus? = nil) -> AgentChatSession {
            var session = AgentChatSession(provider: .claude, projectID: project.id, title: title)
            session.createdManually = true
            session.status = .closed
            session.lastActivityAt = Date().addingTimeInterval(-minutesAgo * 60)
            if let status { store.setStatus(status, for: session.id) }
            return session
        }
        let gus = chat("WM8-69 Gus · Limit: Chats erkennen", wm8, .working)
        let vic = chat("WM8-12 Vic · Neustart ohne Verlust", wm8, .working)
        let fin = chat("WM8-75 Fin · Diktat: Enter", wm8, .working)
        let jarvis = chat("Jarvis: Supervisor WhisperM8", wm8, .idle)
        let una = chat("1 Una · Feedback: Wünsche", lm8, .idle)
        let pia = chat("2 Pia · Linear: Feedback", lm8, .working)
        let lmJarvis = chat("Jarvis: Supervisor ListM8", lm8, .idle)
        let lmStopped = [chat("4 Ben · Fix: Exportierte Leads", lm8, minutesAgo: 18),
                         chat("3 Kit · Kurs: Übersicht", lm8, minutesAgo: 19)]
        let claude = chat("Claude Chat", wm8, .idle)
        let wmStopped = [chat("Ole · Terminal-Tab: fertig", wm8, minutesAgo: 60)]
        let versions = chat("Versionsstand im develop", akq, .idle)

        let wsActive = AgentGridWorkspace(name: "WM8 Aktiv", colorHex: "#7C5CFF",
                                          slots: [gus.id, vic.id, fin.id, jarvis.id], capacity: 4)
        let wsDeal = AgentGridWorkspace(name: "DealSupply", colorHex: "#9E73F2", slots: [una.id, pia.id], capacity: 2)
        let workspaces = [wsActive, wsDeal]
        let bySession = AgentTabOrder.workspaceBySession(gridWorkspaces: workspaces)
        let running: Set<UUID> = [gus.id, vic.id, fin.id, jarvis.id, una.id, pia.id, lmJarvis.id, claude.id, versions.id]
        func blocks(_ sessions: [AgentChatSession]) -> SidebarProjectBlocks {
            AgentSidebarSorting.blocks(sortedSessions: sessions, runningSessionIDs: running,
                                       workspaceBySession: bySession, workspaces: workspaces)
        }
        let all = [gus, vic, fin, jarvis, una, pia, lmJarvis, claude, versions] + lmStopped + wmStopped
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        let projectOf: (UUID) -> AgentProject = { id in
            [wm8, lm8, akq].first { $0.id == byID[id]?.projectID } ?? wm8
        }

        func sectionLabel(_ text: String, plus: Bool = false) -> some View {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(90))
                Text(verbatim: text).font(.system(size: 11, weight: .bold)).tracking(0.6)
                Spacer(minLength: 0)
                if plus {
                    Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(AgentTheme.hover, in: RoundedRectangle(cornerRadius: 4))
                        .padding(.vertical, -3)
                }
            }
            .foregroundStyle(AgentTheme.textTertiary)
            .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 2)
        }

        func workspaceGroup(_ entity: AgentGridWorkspace, selected: UUID) -> some View {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(AgentTheme.textTertiary).frame(width: 14)
                    RoundedRectangle(cornerRadius: 4).fill(Color(hex: entity.colorHex)).frame(width: 15, height: 15)
                        .overlay(Text(verbatim: String(entity.name.prefix(1))).font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white))
                    Text(verbatim: entity.name).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AgentTheme.textPrimary)
                    Spacer(minLength: 0)
                    Text(verbatim: "\(entity.occupiedSessionIDs.count)/\(entity.capacity)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(AgentTheme.textTertiary)
                }
                .padding(.leading, 6).padding(.trailing, 10).frame(height: 28).padding(.horizontal, 8)
                ForEach(Array(entity.occupiedSessionIDs.enumerated()), id: \.offset) { index, id in
                    PinnedSessionRow(
                        session: byID[id]!, project: projectOf(id), isSelected: id == selected,
                        isMultiSelected: false, statusStore: store, isMissingTranscript: false,
                        closeIcon: "minus", closeHelp: nil, slotBadge: "S\(index + 1)",
                        onSelect: {}, onClose: {})
                }
            }
        }

        func group(_ project: AgentProject, _ sessions: [AgentChatSession], selected: UUID) -> some View {
            ProjectChatGroup(
                project: project, blocks: blocks(sessions), isExpanded: true, selectedSessionID: selected,
                multiSelection: [], openTabIDs: Set(sessions.map(\.id)),
                onSelectProject: {}, onToggleExpanded: {}, onSelectSession: { _ in }, onNewChat: { _ in },
                canOpenAsWorkspace: true, onOpenAsWorkspace: {}, onCloseSession: { _ in },
                sidebarScope: .active, onRename: { _, _ in },
                sessionMenu: { _ in AnyView(EmptyView()) }, subagentChildMenu: { _ in AnyView(EmptyView()) },
                statusStore: store, autoRenamingSessionIDs: [],
                onRenameProjectRequest: { _ in }, onSetProjectColor: { _, _ in }, onChooseProjectIcon: { _ in },
                onAutoDetectProjectIcon: { _ in }, onClearProjectIcon: { _ in }, onDeleteProject: { _ in },
                onSessionDrop: { _, _, _ in }, onProjectDrop: { _, _ in })
        }

        func tabBar(width: CGFloat, selected: UUID) -> some View {
            let openTabs = [gus, vic, fin, jarvis, una, pia, lmJarvis, claude, versions] + lmStopped + wmStopped
            let items = AgentTabGrouping.items(
                entries: openTabs.map { AgentTabGroupingEntry(sessionID: $0.id, projectID: $0.projectID) },
                workspaceBySession: bySession, enabled: true)
            func meta(_ key: AgentTabGroupingKey) -> (String, String) {
                switch key {
                case .workspace(let id):
                    let entity = workspaces.first { $0.id == id }!
                    return (entity.name, entity.colorHex)
                case .project(let id):
                    let project = [wm8, lm8, akq].first { $0.id == id }!
                    return (project.name, project.color)
                }
            }
            var counts: [AgentTabGroupingKey: Int] = [:]
            for case .group(let key, let ids) in items { counts[key] = ids.count }
            // Platz wie in der App: Leiste minus Knöpfe (Tab-Menü, Plus) und Ränder.
            let layout = AgentTabWidthResolver.layout(
                items: items, viewportWidth: width - 8 - 6 - 24 - 5 - 22 - 5 - 22 - 5 - 8 - 5 - 24,
                selectedID: selected, manuallyCollapsed: [], manuallyOpened: [],
                chipWidths: Dictionary(uniqueKeysWithValues: counts.map { key, count in
                    (key, AgentChatsView.tabGroupChipWidth(title: meta(key).0, count: count))
                }))
            func tab(_ id: UUID, _ color: Color?) -> some View {
                ChatTabButton(session: byID[id]!, project: projectOf(id), isSelected: id == selected,
                              isMultiSelected: false, statusStore: store, groupColor: color,
                              width: layout.widthByID[id], isNarrow: layout.narrowIDs.contains(id),
                              onSelect: {}, onClose: {})
            }
            func icon(_ name: String) -> some View {
                Image(systemName: name).font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AgentTheme.textSecondary).frame(width: 22, height: 22)
                    .background(AgentTheme.control.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            }
            return HStack(spacing: 5) {
                Image(systemName: "sidebar.left").font(.system(size: 12)).foregroundStyle(AgentTheme.textSecondary)
                    .frame(width: 24, height: 22)
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        switch item {
                        case .single(let id):
                            tab(id, nil)
                        case .group(let key, let ids):
                            let collapsed = layout.autoCollapsedKeys.contains(key)
                            HStack(alignment: .bottom, spacing: 0) {
                                ChatTabGroupLabel(title: meta(key).0, count: ids.count, colorHex: meta(key).1,
                                                  isCollapsed: collapsed, isActive: ids.contains(selected),
                                                  isAutoCollapsed: collapsed, onToggle: {})
                                ForEach(AgentTabOrder.visibleMemberIDs(ids, collapsed: collapsed, selectedID: selected),
                                        id: \.self) { tab($0, Color(hex: meta(key).1)) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: min(layout.contentWidth, width - 140), alignment: .leading)
                .clipped()
                icon("chevron.down")
                icon("plus")
                Spacer(minLength: 8)
                Image(systemName: "sidebar.right").font(.system(size: 12)).foregroundStyle(AgentTheme.textSecondary)
                    .frame(width: 24, height: 22)
            }
            .padding(.leading, 8).padding(.trailing, 6)
            .frame(height: 34, alignment: .bottom)
            .background(AgentTheme.tabBar)
        }

        func window(width: CGFloat) -> AnyView {
            let selected = jarvis.id
            let counts = SidebarScopeCounts(active: 18, recent: 26, all: 315)
            return AnyView(HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarScopeSegments(scope: .active, counts: counts, onSelect: { _ in })
                        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
                    sectionLabel("WORKSPACES", plus: true)
                    workspaceGroup(wsActive, selected: selected)
                    workspaceGroup(wsDeal, selected: selected)
                    sectionLabel("CHATS")
                    group(lm8, [una, pia, lmJarvis] + lmStopped, selected: selected)
                    group(wm8, [gus, vic, fin, jarvis, claude] + wmStopped, selected: selected)
                    group(akq, [versions], selected: selected)
                    Spacer(minLength: 0)
                }
                .frame(width: 270)
                .background(AgentTheme.sidebar)
                VStack(spacing: 0) {
                    tabBar(width: width - 270, selected: selected)
                    Rectangle().fill(AgentTheme.header).frame(height: 30)
                    Spacer(minLength: 0)
                }
                .background(AgentTheme.background)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        }

        return [
            Fixture(name: "seitenleiste-tableiste", size: CGSize(width: 1_360, height: 640)) { window(width: 1_360) },
            Fixture(name: "seitenleiste-tableiste-schmal", size: CGSize(width: 1_000, height: 640)) { window(width: 1_000) },
        ]
    }
}
