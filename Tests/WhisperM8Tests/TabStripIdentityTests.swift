import AppKit
import SwiftUI
import XCTest
@testable import WhisperM8

/// Umgruppierung der Tab-Leiste (WM8-101): Legt man einen Chat mit offenem
/// Tab in einen Workspace, wandert sein Tab in die Gruppe des Workspace. Die
/// übrigen Tabs dürfen dabei nicht neu angelegt werden, und die Leiste soll
/// danach nicht ein zweites Mal ausgewertet werden.
///
/// Messung an der App vor diesem Umbau (16.11.2026, 01:53): je Änderung mit
/// offenem Tab 6 bis 7 neu angelegte Tabs (`appear.tab`) und zwei
/// Auswertungen des Fensters (`body.window`).
@MainActor
final class TabStripIdentityTests: XCTestCase {
    private struct Counts { let appears: Int; let evaluations: Int }

    /// Baut die Leiste mit `from` auf, lässt sie zur Ruhe kommen und zählt
    /// dann nur, was der Wechsel auf `to` auslöst.
    private func countRegroup(
        fixture: TabStripFixture,
        from: [AgentTabGroupingItem],
        to: [AgentTabGroupingItem],
        width: CGFloat
    ) -> Counts {
        let probe = TabStripProbe()
        let host = NSHostingView(rootView: fixture.harness(items: from, probe: probe).frame(width: width, height: 34))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 34)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        settle(host)
        XCTAssertEqual(probe.tabAppears, from.flatMap(Self.ids).count, "Aufbau: nicht alle Tabs angelegt")

        probe.tabAppears = 0
        probe.bodyEvaluations = 0
        host.rootView = fixture.harness(items: to, probe: probe).frame(width: width, height: 34)
        settle(host)
        let counts = Counts(appears: probe.tabAppears, evaluations: probe.bodyEvaluations)
        window.contentView = nil
        window.close()
        return counts
    }

    private func settle(_ host: NSView) {
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    private static func ids(_ item: AgentTabGroupingItem) -> [UUID] {
        switch item {
        case .single(let id): [id]
        case .group(_, let ids): ids
        }
    }

    /// Breit genug, dass keine Gruppe wegen Platzmangel zuklappt: Gemessen
    /// wird nur die Identität, nicht die Breitenregel.
    private let wideWindow: CGFloat = 4_000

    func testTabJoiningAGroupLeavesTheOtherTabsInPlace() {
        let fixture = TabStripFixture()
        let counts = countRegroup(fixture: fixture, from: fixture.items, to: fixture.regroupedItems, width: wideWindow)
        print("WM8-101 Umgruppierung add: appear.tab=\(counts.appears) body=\(counts.evaluations)")
        // Nur der gewanderte Tab entsteht neu (anderer Elternteil).
        XCTAssertLessThanOrEqual(counts.appears, 1, "Tabs neu angelegt: \(counts.appears)")
        XCTAssertEqual(counts.evaluations, 1, "Leiste mehrfach ausgewertet: \(counts.evaluations)")
    }

    func testTabLeavingAGroupLeavesTheOtherTabsInPlace() {
        let fixture = TabStripFixture()
        let counts = countRegroup(fixture: fixture, from: fixture.regroupedItems, to: fixture.items, width: wideWindow)
        print("WM8-101 Umgruppierung remove: appear.tab=\(counts.appears) body=\(counts.evaluations)")
        XCTAssertLessThanOrEqual(counts.appears, 1, "Tabs neu angelegt: \(counts.appears)")
        XCTAssertEqual(counts.evaluations, 1, "Leiste mehrfach ausgewertet: \(counts.evaluations)")
    }

    // MARK: - Identität, pur

    func testIdentityFollowsGroupKeyAndChatNotPosition() {
        let fixture = TabStripFixture()
        let before = AgentTabGrouping.identified(fixture.items)
        let after = AgentTabGrouping.identified(fixture.regroupedItems)
        XCTAssertEqual(before.map(\.item), fixture.items, "Reihenfolge und Inhalt bleiben")
        // Alle Einzel-Tabs außer dem gewanderten behalten ihre ID, obwohl sie aufrücken.
        let stayed = fixture.singles.filter { $0 != fixture.singles[2] }
        for id in stayed {
            XCTAssertTrue(before.contains { $0.id == .single(id, occurrence: 0) })
            XCTAssertTrue(after.contains { $0.id == .single(id, occurrence: 0) })
        }
        XCTAssertFalse(after.contains { $0.id == .single(fixture.singles[2], occurrence: 0) })
        // Die Gruppe behält ihre ID, auch mit einem Mitglied mehr.
        XCTAssertEqual(before.first?.id, .group(fixture.wsActive, occurrence: 0))
        XCTAssertEqual(after.first?.id, .group(fixture.wsActive, occurrence: 0))
    }

    func testIdentityStaysUniqueForDuplicates() {
        let tab = UUID()
        let key = AgentTabGroupingKey.project(UUID())
        let items: [AgentTabGroupingItem] = [
            .single(tab), .group(key: key, sessionIDs: [UUID(), UUID()]), .single(tab), .group(key: key, sessionIDs: [])
        ]
        let ids = AgentTabGrouping.identified(items).map(\.id)
        XCTAssertEqual(Set(ids).count, items.count)
        XCTAssertEqual(ids, [.single(tab, occurrence: 0), .group(key, occurrence: 0),
                             .single(tab, occurrence: 1), .group(key, occurrence: 1)])
    }
}
