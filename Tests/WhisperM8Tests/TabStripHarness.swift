import SwiftUI
@testable import WhisperM8

/// Prüfaufbau für die schrumpfende Tab-Leiste mit ECHTEM Rahmen (WM8-80,
/// Auflage Uli): `TabStripArea` mit den echten Tabs und Chips, dieselbe
/// Messung und Breitenregel wie in `AgentChatsView`, links und rechts feste
/// Knöpfe wie in der Titelleiste. Läuft in einem echten `NSHostingView`; ein
/// Messkreislauf würde hier den Bereich Durchlauf für Durchlauf verbreitern.
@MainActor
final class TabStripProbe {
    var areaWidths: [CGFloat] = []
    var stripWidths: [CGFloat] = []
    var chipMeasurements = 0
    /// Auswertungen des Gerüsts; im Fenster entspricht das `body.window`.
    var bodyEvaluations = 0
    /// Neu angelegte Tabs; im Fenster entspricht das `appear.tab`.
    var tabAppears = 0
}

struct TabStripHarness: View {
    let items: [AgentTabGroupingItem]
    let sessions: [UUID: AgentChatSession]
    let projects: [UUID: AgentProject]
    let groupMeta: [AgentTabGroupingKey: (title: String, colorHex: String)]
    let selected: UUID
    let store: AgentSessionRuntimeStatusStore
    let probe: TabStripProbe

    @State private var areaWidth: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0
    @State private var chipWidths: [AgentTabGroupingKey: CGFloat] = [:]
    @State private var tabFrameBox = TabFrameBox()

    var body: some View {
        probe.bodyEvaluations += 1
        let viewport = AgentTabWidthResolver.stripViewportWidth(areaWidth: areaWidth, trailingWidth: trailingWidth)
        var chips: [AgentTabGroupingKey: CGFloat] = [:]
        for case .group(let key, let ids) in items {
            chips[key] = chipWidths[key]
                ?? AgentChatsView.tabGroupChipWidth(title: groupMeta[key]?.title ?? "", count: ids.count)
        }
        let layout = areaWidth > 0
            ? AgentTabWidthResolver.layout(items: items, viewportWidth: viewport, selectedID: selected,
                                           manuallyCollapsed: [], manuallyOpened: [], chipWidths: chips)
            : AgentTabWidthResolver.Layout()
        let stripWidth: CGFloat? = layout.widthByID.isEmpty ? nil : min(layout.contentWidth, viewport)
        return HStack(spacing: 5) {
            fixedButton("sidebar.left", width: 24)
            TabStripArea(
                stripWidth: stripWidth,
                onMeasure: { area, trailing in
                    if let area, abs(area - areaWidth) > 0.5 {
                        areaWidth = area
                        probe.areaWidths.append(area)
                    }
                    if let trailing, abs(trailing - trailingWidth) > 0.5 { trailingWidth = trailing }
                }
            ) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 6) {
                        // Dieselbe Identität wie in der Leiste des Fensters (WM8-101).
                        ForEach(AgentTabGrouping.identified(items)) { entry in
                            itemView(entry.item, layout: layout)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 34, alignment: .bottom)
                    .coordinateSpace(.named(AgentChatsView.tabStripContentSpace))
                    .onPreferenceChange(TabFramePreferenceKey.self) { tabFrameBox.frames = $0 }
                    .overlay(alignment: .leading) { Color.clear.frame(width: tabFrameBox.frames.isEmpty ? 0 : 1) }
                }
                .background(GeometryReader { geo in
                    Color.clear.onAppear { probe.stripWidths.append(geo.size.width) }
                        .onChange(of: geo.size.width) { _, width in probe.stripWidths.append(width) }
                })
            } trailing: {
                HStack(spacing: 5) {
                    fixedButton("chevron.down", width: 22)
                    fixedButton("plus", width: 22)
                }
            }
            fixedButton("sidebar.right", width: 24)
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: 34, alignment: .bottom)
        .background(AgentTheme.tabBar)
    }

    @ViewBuilder
    private func itemView(_ item: AgentTabGroupingItem, layout: AgentTabWidthResolver.Layout) -> some View {
        switch item {
        case .single(let id):
            tab(id, color: nil, layout: layout)
        case .group(let key, let ids):
            let collapsed = layout.autoCollapsedKeys.contains(key)
            let meta = groupMeta[key] ?? ("", AgentGridWorkspace.defaultColorHex)
            HStack(alignment: .bottom, spacing: 0) {
                ChatTabGroupLabel(title: meta.title, count: ids.count, colorHex: meta.colorHex,
                                  isCollapsed: collapsed, isActive: ids.contains(selected),
                                  isAutoCollapsed: collapsed, onToggle: {})
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                        probe.chipMeasurements += 1
                        if abs(width - (chipWidths[key] ?? -1)) > 0.5 { chipWidths[key] = width }
                    }
                ForEach(AgentTabOrder.visibleMemberIDs(ids, collapsed: collapsed, selectedID: selected), id: \.self) {
                    tab($0, color: Color(hex: meta.colorHex), layout: layout)
                }
            }
        }
    }

    private func tab(_ id: UUID, color: Color?, layout: AgentTabWidthResolver.Layout) -> some View {
        let session = sessions[id]!
        return ChatTabButton(
            session: session, project: projects[session.projectID], isSelected: id == selected,
            isMultiSelected: false, statusStore: store, groupColor: color,
            width: layout.widthByID[id], isNarrow: layout.narrowIDs.contains(id),
            onSelect: {}, onClose: {})
        .onAppear { probe.tabAppears += 1 }
        // Rahmen je Tab für die Einfügelinie, wie in der Leiste des Fensters.
        .background(GeometryReader { geo in
            Color.clear.preference(
                key: TabFramePreferenceKey.self,
                value: [id: geo.frame(in: .named(AgentChatsView.tabStripContentSpace))])
        })
        .id(id)
    }

    private func fixedButton(_ symbol: String, width: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(AgentTheme.textSecondary)
            .frame(width: width, height: 22)
    }

    /// 18 Tabs wie im Zwilling: zwei Gruppen und viele Einzel-Tabs.
    @MainActor
    static func sample(probe: TabStripProbe) -> TabStripHarness {
        let fixture = TabStripFixture()
        return fixture.harness(items: fixture.items, probe: probe)
    }
}

/// Feste Chats für das Gerüst. Dieselben IDs in mehreren Aufbauten, damit ein
/// Test eine Umgruppierung nachstellen kann (WM8-101).
@MainActor
struct TabStripFixture {
    let store: AgentSessionRuntimeStatusStore
    let sessions: [UUID: AgentChatSession]
    let projects: [UUID: AgentProject]
    let active: [UUID]
    let deal: [UUID]
    let singles: [UUID]
    let wsActive = AgentTabGroupingKey.workspace(UUID())
    let wsDeal = AgentTabGroupingKey.workspace(UUID())

    init() {
        let wm8 = AgentProject(name: "whisperm8", path: "/tmp/whisperm8", color: "#3D6DF2", createdManually: true)
        let lm8 = AgentProject(name: "ListM8", path: "/tmp/ListM8", color: "#E8590C", createdManually: true)
        let store = AgentSessionRuntimeStatusStore()
        self.store = store
        func chat(_ title: String, _ project: AgentProject, _ status: AgentSessionRuntimeStatus) -> AgentChatSession {
            let session = AgentChatSession(provider: .claude, projectID: project.id, title: title)
            store.setStatus(status, for: session.id)
            return session
        }
        let active = [chat("WM8-69 Gus · Limit: Chats erkennen", wm8, .working),
                      chat("WM8-12 Vic · Neustart ohne Verlust", wm8, .awaitingInput),
                      chat("WM8-75 Fin · Diktat: Enter", wm8, .working),
                      chat("Jarvis: Supervisor WhisperM8", wm8, .idle)]
        let deal = [chat("1 Una · Feedback: Wünsche", lm8, .idle), chat("2 Pia · Linear: Feedback", lm8, .working),
                    chat("3 Kit · Kurs: Übersicht", lm8, .idle), chat("4 Ben · Fix: Exportierte Leads", lm8, .idle),
                    chat("5 Max · MCP: Kampagnen", lm8, .idle)]
        let singles = (1...9).map { chat("WM8-\($0 + 80) Tab\($0) · Einzelner Chat Nummer \($0)", wm8, .idle) }
        self.sessions = Dictionary(uniqueKeysWithValues: (active + deal + singles).map { ($0.id, $0) })
        self.projects = [wm8.id: wm8, lm8.id: lm8]
        self.active = active.map(\.id)
        self.deal = deal.map(\.id)
        self.singles = singles.map(\.id)
    }

    var selected: UUID { active[3] }

    var items: [AgentTabGroupingItem] {
        [.group(key: wsActive, sessionIDs: active), .group(key: wsDeal, sessionIDs: deal)]
            + singles.map { .single($0) }
    }

    /// Wie nach `chats workspace add`: Der dritte Einzel-Tab liegt jetzt im
    /// Workspace „WM8 Aktiv“ und wandert in dessen Gruppe.
    var regroupedItems: [AgentTabGroupingItem] {
        let moved = singles[2]
        return [.group(key: wsActive, sessionIDs: active + [moved]), .group(key: wsDeal, sessionIDs: deal)]
            + singles.filter { $0 != moved }.map { .single($0) }
    }

    func harness(items: [AgentTabGroupingItem], probe: TabStripProbe) -> TabStripHarness {
        TabStripHarness(
            items: items,
            sessions: sessions,
            projects: projects,
            groupMeta: [wsActive: ("WM8 Aktiv", "#7C5CFF"), wsDeal: ("DealSupply", "#9E73F2")],
            selected: selected,
            store: store,
            probe: probe)
    }
}
