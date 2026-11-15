import CoreGraphics
import Foundation

/// Breitenregel der Tab-Leiste, Tabs 1 „Schrumpfen“ (WM8-80, Paket 5).
///
/// Stufen, wenn es eng wird:
/// 1. Alle Tabs teilen sich den Platz gleich, höchstens 190 pt; der aktive
///    Tab bekommt mindestens 140 pt.
/// 2. Reicht das nicht für 100 pt je Tab, klappen Gruppen ohne den aktiven Tab
///    von selbst zu, die größte zuerst. Von Hand geöffnete oder geschlossene
///    Gruppen fasst die Regel nicht an.
/// 3. Danach werden Tabs bis 64 pt schmal und zeigen einen Kurztitel.
/// 4. Erst darunter scrollt die Leiste.
///
/// Pur: Die Ansicht reicht Elemente, Breite des sichtbaren Streifens und die
/// Breite der Gruppen-Chips herein und bekommt Breiten zurück.
enum AgentTabWidthResolver {
    static let maxWidth: CGFloat = 190
    static let minWidth: CGFloat = 100
    static let narrowMinWidth: CGFloat = 64
    static let activeMinWidth: CGFloat = 140
    /// Abstand zwischen Elementen (Einzeltab oder Gruppe) und Rand innen.
    static let itemSpacing: CGFloat = 6
    static let horizontalPadding: CGFloat = 16

    struct Layout: Equatable {
        var widthByID: [UUID: CGFloat] = [:]
        /// Gruppen, die die Regel wegen Platzmangel zugeklappt hat.
        var autoCollapsedKeys: Set<AgentTabGroupingKey> = []
        /// Tabs mit Kurztitel und ohne Schließen-Knopf.
        var narrowIDs: Set<UUID> = []
        /// Breite des ganzen Inhalts samt Chips, Abständen und Rand. Ist sie
        /// größer als der Platz, scrollt die Leiste.
        var contentWidth: CGFloat = 0
    }

    static func layout(
        items: [AgentTabGroupingItem],
        viewportWidth: CGFloat,
        selectedID: UUID?,
        manuallyCollapsed: Set<AgentTabGroupingKey>,
        manuallyOpened: Set<AgentTabGroupingKey>,
        /// Mehrfach ausgewählte Tabs: Ihre Gruppe klappt nicht von selbst zu,
        /// sonst träfen Sammelaktionen Tabs, die man nicht mehr sieht.
        protectedIDs: Set<UUID> = [],
        chipWidth: (AgentTabGroupingKey) -> CGFloat
    ) -> Layout {
        var autoCollapsed = Set<AgentTabGroupingKey>()
        var share = share(items: items, viewport: viewportWidth, selectedID: selectedID,
                          collapsed: manuallyCollapsed, chipWidth: chipWidth)
        let candidates: [(key: AgentTabGroupingKey, count: Int)] = items.compactMap { item in
            guard case .group(let key, let ids) = item,
                  !manuallyCollapsed.contains(key), !manuallyOpened.contains(key),
                  !ids.contains(where: { $0 == selectedID || protectedIDs.contains($0) })
            else { return nil }
            return (key, ids.count)
        }
        // Stabil: bei gleicher Größe gewinnt die weiter links stehende Gruppe.
        var queue = candidates.enumerated()
            .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
            .map(\.element.key)
        while share.other < minWidth, !queue.isEmpty {
            autoCollapsed.insert(queue.removeFirst())
            share = Self.share(items: items, viewport: viewportWidth, selectedID: selectedID,
                               collapsed: manuallyCollapsed.union(autoCollapsed), chipWidth: chipWidth)
        }
        let other = max(narrowMinWidth, share.other)
        var widths: [UUID: CGFloat] = [:]
        var narrow = Set<UUID>()
        for id in share.visible {
            if id == selectedID {
                widths[id] = share.active
            } else {
                widths[id] = other
                if other < minWidth { narrow.insert(id) }
            }
        }
        let content = share.fixed + share.visible.reduce(0) { $0 + (widths[$1] ?? 0) }
        return Layout(widthByID: widths, autoCollapsedKeys: autoCollapsed, narrowIDs: narrow, contentWidth: content)
    }

    private static func share(
        items: [AgentTabGroupingItem],
        viewport: CGFloat,
        selectedID: UUID?,
        collapsed: Set<AgentTabGroupingKey>,
        chipWidth: (AgentTabGroupingKey) -> CGFloat
    ) -> (visible: [UUID], fixed: CGFloat, active: CGFloat, other: CGFloat) {
        var visible: [UUID] = []
        var fixed = horizontalPadding + itemSpacing * CGFloat(max(0, items.count - 1))
        for item in items {
            switch item {
            case .single(let id):
                visible.append(id)
            case .group(let key, let ids):
                fixed += chipWidth(key)
                visible += AgentTabOrder.visibleMemberIDs(ids, collapsed: collapsed.contains(key), selectedID: selectedID)
            }
        }
        let available = max(0, viewport - fixed)
        let count = visible.count
        guard count > 0 else { return ([], fixed, 0, maxWidth) }
        let hasSelected = selectedID.map(visible.contains) ?? false
        let even = available / CGFloat(count)
        let active = hasSelected ? min(maxWidth, max(activeMinWidth, even)) : 0
        let rest = count - (hasSelected ? 1 : 0)
        let other = rest > 0 ? min(maxWidth, (available - active) / CGFloat(rest)) : maxWidth
        return (visible, fixed, active, other)
    }

    /// Kurztitel für schmale Tabs: der Teil vor dem ersten „ · “ ohne
    /// Ticket-Nummer („WM8-69 Gus · Limit …“ → „Gus“), sonst das erste Wort.
    static func shortTitle(_ title: String) -> String {
        if let range = title.range(of: " · ") {
            var head = String(title[..<range.lowerBound])
            if let match = head.range(of: #"^[A-Za-z]+[0-9]*-\d+\s+"#, options: .regularExpression) {
                head.removeSubrange(match)
            } else if let match = head.range(of: #"^\d+\s+"#, options: .regularExpression) {
                head.removeSubrange(match)
            }
            return head.isEmpty ? title : head
        }
        let first = title.split(whereSeparator: { $0 == " " || $0 == ":" }).first.map(String.init)
        return first ?? title
    }
}
