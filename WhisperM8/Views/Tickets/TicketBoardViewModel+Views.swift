import AppKit
import Foundation

// MARK: - Reiter und Gruppen der Liste (WM8-125)

extension TicketBoardViewModel {
    /// Neue Reiter oder ein anderer gezeigter Reiter (vom Controller). Ändert
    /// nur, was sich wirklich geändert hat: Jede Zuweisung zeichnet den Kopf neu.
    func setViews(_ fresh: TicketViewCatalog, active: String?, isLoading: Bool) {
        if fresh != catalog { catalog = fresh }
        if active != activeViewID { activeViewID = active }
        if isLoading != isViewLoading { isViewLoading = isLoading }
    }

    /// Klick auf einen Reiter (oder Kreuz/Return im Kopf). Triage und Auswahl
    /// gehören zur alten Ansicht.
    func selectView(_ id: String) {
        guard id != activeViewID, catalog.views.contains(where: { $0.id == id }) else { return }
        setTriage(nil)
        selectedKey = nil
        activeViewID = id
        onSelectView?(id)
        onControllerViewChange?()
    }

    /// Überschrift der kopierten Liste: Board und Ansicht.
    func listTitle(board: String) -> String {
        guard let name = activeView?.name else { return board }
        return board.isEmpty ? name : board + " · " + name
    }

    var activeView: TicketView? {
        catalog.views.first { $0.id == activeViewID }
    }

    private func collapseKey(_ groupID: String) -> String {
        (activeViewID ?? "") + "|" + groupID
    }

    func isCollapsed(_ groupID: String) -> Bool {
        collapsedGroups.contains(collapseKey(groupID))
    }

    /// Klick auf den Kopf einer Gruppe, Return oder Kreuz darauf.
    func toggleGroup(_ groupID: String) {
        setGroup(groupID, collapsed: !isCollapsed(groupID))
    }

    func setGroup(_ groupID: String, collapsed: Bool) {
        let key = collapseKey(groupID)
        guard collapsed != collapsedGroups.contains(key) else { return }
        if collapsed { collapsedGroups.insert(key) } else { collapsedGroups.remove(key) }
        // Ein gewähltes Ticket in einer zugeklappten Gruppe wäre unsichtbar gewählt.
        if collapsed, let key = selectedKey, triage == nil,
           presentation.groups.first(where: { $0.id == groupID })?.rows.contains(where: { $0.id == key }) == true {
            selectedKey = nil
            selectedGroupID = groupID
        }
        if let triage {
            let reconciled = TicketBoardSelection.reconcile(triage, fresh: keys(for: triage.source))
            if reconciled != triage { setTriage(reconciled) }
        }
    }

    /// Reiter in der Zeile und unter „Mehr“, nach der gemessenen Breite.
    var tabs: TicketViewTabs {
        TicketViewTabs.split(catalog.views, active: activeViewID, width: tabsWidth, measure: TicketViewTabMetrics.width)
    }

    /// Die Ansicht meldet die Breite der Reiterzeile.
    func setTabsWidth(_ width: CGFloat) {
        let rounded = width.rounded()
        if tabsWidth != rounded { tabsWidth = rounded }
    }

    /// Gruppen, deren Tickets gerade zu sehen sind (aufgeklappt).
    var openGroups: [TicketListGroup] {
        presentation.groups.filter { !isCollapsed($0.id) }
    }
}

// MARK: - Welche Reiter in die Zeile passen

/// Reiter in der Zeile und der Rest unter „Mehr“ (Entscheidung Giuliano,
/// 16.11.2026). Der gezeigte Reiter steht immer in der Zeile.
struct TicketViewTabs: Equatable {
    var shown: [TicketView]
    var more: [TicketView]

    /// Platz für „Mehr · 3 ▾“ und den Abstand zwischen zwei Reitern.
    static let moreWidth: CGFloat = 84
    static let spacing: CGFloat = 2

    /// - Parameters:
    ///   - width: Breite der Zeile; `nil`, solange sie nicht gemessen ist (dann alle).
    ///   - measure: Breite eines Reiters samt Innenabstand.
    static func split(_ views: [TicketView], active: String?, width: CGFloat?,
                      measure: (TicketView) -> CGFloat) -> TicketViewTabs {
        guard let width else { return TicketViewTabs(shown: views, more: []) }
        let widths = views.map(measure)
        let total = widths.reduce(0, +) + spacing * CGFloat(max(views.count - 1, 0))
        if total <= width { return TicketViewTabs(shown: views, more: []) }
        let room = width - moreWidth
        var indices: [Int] = []
        var used: CGFloat = 0
        for (index, w) in widths.enumerated() {
            let next = used + (indices.isEmpty ? 0 : spacing) + w
            guard next <= room else { break }
            indices.append(index)
            used = next
        }
        // Der gezeigte Reiter steht immer in der Zeile, notfalls statt der letzten.
        if let active, let activeIndex = views.firstIndex(where: { $0.id == active }), !indices.contains(activeIndex) {
            indices.append(activeIndex)
            used += spacing + widths[activeIndex]
            while used > room, indices.count > 1 {
                let dropped = indices.remove(at: indices.count - 2)
                used -= spacing + widths[dropped]
            }
        }
        let shownSet = Set(indices)
        return TicketViewTabs(shown: indices.sorted().map { views[$0] },
                              more: views.indices.filter { !shownSet.contains($0) }.map { views[$0] })
    }
}

/// Breite eines Reiters, wie `TicketViewTabButton` ihn zeichnet. Je Name einmal
/// gemessen (wenige Namen, die sich selten ändern).
@MainActor
enum TicketViewTabMetrics {
    static let fontSize: CGFloat = 12.5
    static let horizontalPadding: CGFloat = 10
    private static var cache: [String: CGFloat] = [:]

    static func width(_ view: TicketView) -> CGFloat {
        if let hit = cache[view.name] { return hit }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let text = (view.name as NSString).size(withAttributes: [.font: font]).width
        let width = ceil(text) + horizontalPadding * 2 + 2
        cache[view.name] = width
        return width
    }
}

/// Kopf einer Gruppe als Stelle der Liste (Controller, Pfeiltasten).
enum TicketListStop {
    static let prefix = "group:"

    static func group(_ id: String) -> String { prefix + id }

    /// ID der Gruppe, wenn die Stelle ein Kopf ist; Ticket-Nummern beginnen nie so.
    static func groupID(_ stop: String) -> String? {
        stop.hasPrefix(prefix) ? String(stop.dropFirst(prefix.count)) : nil
    }
}
