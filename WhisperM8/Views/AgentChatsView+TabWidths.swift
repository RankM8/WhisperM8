import AppKit
import SwiftUI

/// Zustand der schrumpfenden Tab-Leiste (WM8-80, Paket 5). Bewusst ephemer
/// wie `collapsedTabGroups`: Eine von Hand geöffnete Gruppe bleibt offen bis
/// zum Neustart der App (Entscheidung Giuliano, 15.11.2026).
struct TabStripWidthState: Equatable {
    /// Breite des Bereichs aus Streifen und den Knöpfen dahinter. Hängt nur
    /// am Fenster, nie an den Tab-Breiten — so gibt es keinen Messkreislauf.
    var availableWidth: CGFloat = 0
    /// Breite der Knöpfe hinter dem Streifen (Gruppen, Alle Tabs, Plus).
    var trailingWidth: CGFloat = 0
    /// Gruppen, die nach dem Zuklappen wegen Platzmangel von Hand geöffnet
    /// wurden; die Regel fasst sie nicht mehr an.
    var openedGroups: Set<AgentTabGroupingKey> = []
    /// Gemessene Breite je Gruppen-Chip. Sie hängt nur an Titel und Zahl,
    /// nicht an den Tab-Breiten; bis zur ersten Messung gilt die Schätzung.
    var chipWidths: [AgentTabGroupingKey: CGFloat] = [:]
}

extension AgentChatsView {
    /// Platz, den der Streifen selbst haben darf.
    var tabStripViewportWidth: CGFloat {
        AgentTabWidthResolver.stripViewportWidth(
            areaWidth: tabStripWidth.availableWidth, trailingWidth: tabStripWidth.trailingWidth)
    }

    /// Breiten aller sichtbaren Tabs. Vor der ersten Messung leer: Dann
    /// gelten die alten Grenzen 100–190 pt, bis der Platz bekannt ist.
    var tabWidthLayout: AgentTabWidthResolver.Layout {
        tabWidthLayout(items: tabGroupingItems)
    }

    func tabWidthLayout(items: [AgentTabGroupingItem]) -> AgentTabWidthResolver.Layout {
        guard tabStripWidth.availableWidth > 0 else { return AgentTabWidthResolver.Layout() }
        // Chip-Breiten einmal je Lauf: gemessen, sonst geschätzt.
        var chipWidths: [AgentTabGroupingKey: CGFloat] = [:]
        for case .group(let key, let ids) in items {
            chipWidths[key] = tabStripWidth.chipWidths[key]
                ?? Self.tabGroupChipWidth(title: tabGroupMetadata(for: key).title, count: ids.count)
        }
        return AgentTabWidthResolver.layout(
            items: items,
            viewportWidth: tabStripViewportWidth,
            selectedID: selectedSessionID,
            manuallyCollapsed: collapsedTabGroups,
            manuallyOpened: tabStripWidth.openedGroups,
            protectedIDs: multiSelection,
            chipWidths: chipWidths
        )
    }

    /// Eingeklappt von Hand oder wegen Platzmangel. Gilt überall, wo die
    /// Leiste sichtbare Tabs oder Drop-Slots braucht.
    var effectiveCollapsedTabGroups: Set<AgentTabGroupingKey> {
        collapsedTabGroups.union(tabWidthLayout.autoCollapsedKeys)
    }

    /// Klick auf den Gruppen-Chip. Eine wegen Platzmangel zugeklappte Gruppe
    /// geht auf und bleibt offen; eine offene geht von Hand zu.
    func toggleTabGroup(_ key: AgentTabGroupingKey, sessionIDs: [UUID], isCollapsed: Bool) {
        if isCollapsed {
            collapsedTabGroups.remove(key)
            tabStripWidth.openedGroups.insert(key)
        } else {
            tabStripWidth.openedGroups.remove(key)
            collapsedTabGroups.insert(key)
            // Eingeklappte Mitglieder verschwinden aus der Leiste. Blieben sie
            // ausgewählt, würden Bulk-Aktionen („N Tabs schließen/archivieren")
            // Chats treffen, die der User nicht mehr sieht — bei Terminal-
            // Sessions unwiderruflich.
            let hidden = Set(sessionIDs)
                .subtracting(AgentTabOrder.visibleMemberIDs(sessionIDs, collapsed: true, selectedID: selectedSessionID))
            if !hidden.isEmpty { multiSelection.subtract(hidden) }
        }
    }

    /// Breite des Gruppen-Chips (`ChatTabGroupLabel`): Außenabstand 2 + 5,
    /// Innenabstand 2 × 7, Winkel 6, zwei Lücken à 4, Titel höchstens 110.
    static func tabGroupChipWidth(title: String, count: Int) -> CGFloat {
        let titleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let countFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let titleWidth = (title as NSString).size(withAttributes: [.font: titleFont]).width
        let countWidth = ("\(count)" as NSString).size(withAttributes: [.font: countFont]).width
        return 2 + 5 + 14 + 6 + 8 + min(110, ceil(titleWidth)) + ceil(countWidth)
    }

    /// Nimmt die Messungen von `TabStripArea` und den Chips entgegen. Alle
    /// drei hängen nur an Fenster, Knöpfen bzw. Chip-Titeln, nicht an den
    /// Tab-Breiten (Begründung an `TabStripArea`).
    func updateTabStripWidth(
        available: CGFloat? = nil,
        trailing: CGFloat? = nil,
        chips: [AgentTabGroupingKey: CGFloat]? = nil
    ) {
        var next = tabStripWidth
        if let available, abs(available - next.availableWidth) > 0.5 { next.availableWidth = available }
        if let trailing, abs(trailing - next.trailingWidth) > 0.5 { next.trailingWidth = trailing }
        if let chips {
            for (key, width) in chips where abs(width - (next.chipWidths[key] ?? -1)) > 0.5 {
                next.chipWidths[key] = width
            }
        }
        if next != tabStripWidth { tabStripWidth = next }
    }
}
