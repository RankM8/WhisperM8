import SwiftUI
@testable import WhisperM8

/// Tabs 1 „Schrumpfen“ (WM8-80, Paket 5): 18 offene Tabs in zwei Gruppen und
/// einzeln, gezeichnet mit den echten Tabs und Chips und den Breiten der
/// Regel. Breit: Gruppen ohne aktiven Tab klappen zu. Schmal: Kurztitel.
extension UISnapshotGallery {
    @MainActor
    static func tabWidthFixtures() -> [Fixture] {
        let statusStore = AgentSessionRuntimeStatusStore()
        let wm8 = AgentProject(name: "whisperm8", path: "/tmp/whisperm8", color: "#3D6DF2", createdManually: true)
        let shop = AgentProject(name: "shop-backend", path: "/tmp/shop-backend", color: "#E8590C", createdManually: true)
        func chat(_ title: String, _ project: AgentProject, _ status: AgentSessionRuntimeStatus) -> AgentChatSession {
            let session = AgentChatSession(provider: .claude, projectID: project.id, title: title)
            statusStore.setStatus(status, for: session.id)
            return session
        }
        let active = [
            chat("WM8-69 Gus · Limit: Chats erkennen", wm8, .working),
            chat("WM8-12 Vic · Neustart ohne Verlust", wm8, .awaitingInput),
            chat("WM8-75 Fin · Diktat: Enter", wm8, .working),
            chat("Jarvis: Supervisor WhisperM8", wm8, .idle),
        ]
        let shopTabs = [
            chat("1 Una · Rechnungen exportieren", shop, .idle),
            chat("2 Pia · Warenkorb: Rabatt", shop, .working),
            chat("3 Kit · Suche: Filter", shop, .idle),
            chat("4 Ben · Fix: Versandkosten", shop, .idle),
            chat("5 Max · Export: CSV-Spalten", shop, .idle),
        ]
        let singles = (1...9).map { chat("WM8-\($0 + 80) Tab\($0) · Einzelner Chat Nummer \($0)", wm8, .idle) }
        let wsActive = AgentTabGroupingKey.workspace(UUID())
        let wsShop = AgentTabGroupingKey.workspace(UUID())
        let items: [AgentTabGroupingItem] = [.group(key: wsActive, sessionIDs: active.map(\.id))]
            + [.group(key: wsShop, sessionIDs: shopTabs.map(\.id))] + singles.map { .single($0.id) }
        let byID = Dictionary(uniqueKeysWithValues: (active + shopTabs + singles).map { ($0.id, $0) })
        let meta: [AgentTabGroupingKey: (String, String)] = [wsActive: ("WM8 Aktiv", "#7C5CFF"), wsShop: ("Shop-Admin", "#9E73F2")]
        let selected = active[3].id

        func strip(width: CGFloat) -> AnyView {
            let layout = AgentTabWidthResolver.layout(
                items: items, viewportWidth: width, selectedID: selected,
                manuallyCollapsed: [], manuallyOpened: [],
                chipWidths: [
                    wsActive: AgentChatsView.tabGroupChipWidth(title: "WM8 Aktiv", count: 4),
                    wsShop: AgentChatsView.tabGroupChipWidth(title: "Shop-Admin", count: 5),
                ])
            func tab(_ id: UUID, color: Color?) -> some View {
                ChatTabButton(
                    session: byID[id]!, project: byID[id]!.projectID == wm8.id ? wm8 : shop,
                    isSelected: id == selected, isMultiSelected: false, statusStore: statusStore,
                    groupColor: color, width: layout.widthByID[id], isNarrow: layout.narrowIDs.contains(id),
                    onSelect: {}, onClose: {})
            }
            return AnyView(VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "\(Int(width)) pt · zugeklappt: \(layout.autoCollapsedKeys.count) · schmal: \(layout.narrowIDs.count)")
                    .font(.system(size: 11)).foregroundStyle(AgentTheme.textSecondary)
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        switch item {
                        case .single(let id):
                            tab(id, color: nil)
                        case .group(let key, let ids):
                            let collapsed = layout.autoCollapsedKeys.contains(key)
                            let color = Color(hex: meta[key]!.1)
                            HStack(alignment: .bottom, spacing: 0) {
                                ChatTabGroupLabel(title: meta[key]!.0, count: ids.count, colorHex: meta[key]!.1,
                                                  isCollapsed: collapsed, isActive: ids.contains(selected),
                                                  isAutoCollapsed: collapsed, onToggle: {})
                                ForEach(AgentTabOrder.visibleMemberIDs(ids, collapsed: collapsed, selectedID: selected), id: \.self) {
                                    tab($0, color: color)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: width, height: 34, alignment: .bottomLeading)
                .clipped()
                .background(AgentTheme.tabBar)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(AgentTheme.header))
        }
        // Mit echtem Rahmen (`TabStripArea`, Messung wie in der App): 18 Tabs
        // in einem schmalen Fenster. Liefe die Messung im Kreis, stünde die
        // Leiste hier über den Rand hinaus und Plus/Kontext-Knopf fehlten.
        func framed(width: CGFloat) -> AnyView {
            AnyView(TabStripHarness.sample(probe: TabStripProbe())
                .frame(width: width, height: 34)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(AgentTheme.header))
        }
        return [
            Fixture(name: "tabs-schrumpfen-breit", size: CGSize(width: 1_400, height: 80)) { strip(width: 1_360) },
            Fixture(name: "tabs-schrumpfen-schmal", size: CGSize(width: 1_000, height: 80)) { strip(width: 960) },
            Fixture(name: "tabs-schrumpfen-rahmen-schmal", size: CGSize(width: 640, height: 34)) { framed(width: 640) },
            Fixture(name: "tabs-schrumpfen-rahmen-mittel", size: CGSize(width: 1_000, height: 34)) { framed(width: 1_000) },
        ]
    }
}
