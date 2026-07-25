import XCTest
@testable import WhisperM8

/// Drop-Slots der Tab-Leiste: eine eingeklappte Gruppe ist EIN unteilbarer
/// Block, und die Einfügeposition schnappt immer auf eine Grenze, die der
/// Drop danach auch einhalten kann. Reine Logik — die Szenarien entsprechen
/// den im HTML-Mockup durchgespielten Fällen.
final class AgentTabStripSlotTests: XCTestCase {
    private let workspace = UUID()
    private let a = UUID(), b = UUID(), c = UUID()
    private let foreign = UUID(), trailing = UUID()

    private var groupKey: AgentTabGroupingKey { .workspace(workspace) }

    /// Leiste: [Gruppe(a,b,c)] [foreign] [trailing]
    private var items: [AgentTabGroupingItem] {
        [
            .group(key: groupKey, sessionIDs: [a, b, c]),
            .single(foreign),
            .single(trailing)
        ]
    }

    private func slots(collapsed: Bool) -> [AgentTabStripSlot] {
        AgentTabGrouping.slots(
            items: items,
            collapsedKeys: collapsed ? [groupKey] : []
        )
    }

    /// Herkunft der Fixture-Sessions: nur a/b/c teilen eine Gruppe.
    private func fixtureOrigin(_ id: UUID) -> AgentTabGroupingKey? {
        [a, b, c].contains(id) ? groupKey : nil
    }

    /// `movingOrigin: nil` = der bewegte Tab hat keinen Partner in der Leiste,
    /// mit dem er nach dem Drop einen Cluster bilden würde.
    private func snapped(
        _ requested: Int,
        slots: [AgentTabStripSlot],
        moving: Set<UUID>,
        origin: AgentTabGroupingKey? = nil,
        originOf: ((UUID) -> AgentTabGroupingKey?)? = nil,
        grouping: Bool = true
    ) -> Int {
        AgentTabGrouping.snappedInsertionIndex(
            requested: requested,
            slots: slots,
            movingIDs: moving,
            movingOrigin: origin,
            originOfSession: originOf ?? fixtureOrigin,
            groupingEnabled: grouping
        )
    }

    // MARK: - Slot-Aufbau

    func testExpandedGroupYieldsOneSlotPerMember() {
        XCTAssertEqual(slots(collapsed: false), [
            .tab(id: a, groupKey: groupKey),
            .tab(id: b, groupKey: groupKey),
            .tab(id: c, groupKey: groupKey),
            .tab(id: foreign, groupKey: nil),
            .tab(id: trailing, groupKey: nil)
        ])
    }

    func testCollapsedGroupIsExactlyOneSlot() {
        XCTAssertEqual(slots(collapsed: true), [
            .collapsedGroup(key: groupKey, memberIDs: [a, b, c]),
            .tab(id: foreign, groupKey: nil),
            .tab(id: trailing, groupKey: nil)
        ])
    }

    /// Kernpunkt gegen den alten Zustand: Auch eingeklappt hat die Gruppe
    /// Grenzen davor UND dahinter — man kann an ihr vorbeiziehen, ohne dass
    /// sie sich beim Drag von selbst öffnen muss.
    func testCollapsedGroupOffersBoundariesOnBothSides() {
        let collapsed = slots(collapsed: true)
        XCTAssertEqual(snapped(0, slots: collapsed, moving: [foreign]), 0)
        XCTAssertEqual(snapped(1, slots: collapsed, moving: [foreign]), 1)
    }

    // MARK: - Fremde Tabs spalten keine Gruppe

    func testForeignTabSnapsOutOfClusterInterior() {
        let expanded = slots(collapsed: false)
        // Grenze 1 liegt zwischen a und b → an die vordere Kante (0).
        XCTAssertEqual(snapped(1, slots: expanded, moving: [foreign]), 0)
        // Grenze 2 liegt zwischen b und c → an die hintere Kante (3).
        XCTAssertEqual(snapped(2, slots: expanded, moving: [foreign]), 3)
    }

    func testWholeGroupNeverLandsInsideAnotherCluster() {
        let other = UUID()
        let otherA = UUID(), otherB = UUID()
        let otherKey = AgentTabGroupingKey.project(other)
        let mixed: [AgentTabGroupingItem] = [
            .group(key: groupKey, sessionIDs: [a, b]),
            .group(key: otherKey, sessionIDs: [otherA, otherB])
        ]
        let slots = AgentTabGrouping.slots(items: mixed, collapsedKeys: [])
        // Grenze 3 läge zwischen otherA und otherB.
        let index = snapped(
            3, slots: slots, moving: [a, b], origin: groupKey,
            originOf: { [self.a, self.b].contains($0) ? self.groupKey : otherKey }
        )
        XCTAssertTrue(index == 2 || index == 4, "Gruppe landete im fremden Cluster: \(index)")
    }

    // MARK: - Mitglieder bleiben in ihrem Cluster

    func testMemberIsClampedToOwnClusterSpan() {
        let expanded = slots(collapsed: false)
        XCTAssertEqual(
            snapped(expanded.count, slots: expanded, moving: [b], origin: groupKey), 3
        )
        XCTAssertEqual(snapped(0, slots: expanded, moving: [b], origin: groupKey), 0)
    }

    func testMemberKeepsExactPositionInsideOwnCluster() {
        let expanded = slots(collapsed: false)
        XCTAssertEqual(snapped(2, slots: expanded, moving: [a], origin: groupKey), 2)
    }

    // MARK: - Herkunft kommt von der Session, nicht aus den Ziel-Slots
    //
    // Diese Fälle brachen, solange die Zugehörigkeit aus den sichtbaren Slots
    // abgeleitet wurde: dort taucht ein Mitglied einer EINGEKLAPPTEN Gruppe
    // gar nicht auf, ein Chat aus einem anderen Fenster ebenso wenig, und ein
    // noch geschlossener Sidebar-Chat erst recht nicht. Folge war jeweils ein
    // Drop, dessen Ergebnis woanders lag als die Einfügelinie — und eine
    // still auseinanderlaufende gespeicherte Reihenfolge.

    func testMemberOfCollapsedGroupStaysAtItsGroup() {
        let collapsed = slots(collapsed: true)
        XCTAssertEqual(
            snapped(collapsed.count, slots: collapsed, moving: [b], origin: groupKey),
            1,
            "Mitglied muss an seiner Gruppe bleiben, nicht ans Leistenende springen"
        )
    }

    func testIncomingSameOriginTabLandsAtItsFutureCluster() {
        let incoming = UUID()
        let expanded = slots(collapsed: false)
        XCTAssertEqual(
            snapped(
                expanded.count, slots: expanded, moving: [incoming], origin: groupKey,
                originOf: { [self.a, self.b, self.c, incoming].contains($0) ? self.groupKey : nil }
            ),
            3,
            "Zuwanderer derselben Herkunft gehört an die Cluster-Kante"
        )
    }

    /// Sidebar-Chat, dessen Herkunft bisher nur als EINZELTAB offen ist —
    /// die Gruppe entsteht erst durch den Drop.
    func testSidebarTabSnapsToFutureGroupPartner() {
        let partner = UUID()
        let incoming = UUID()
        let key = AgentTabGroupingKey.project(UUID())
        let flat = AgentTabGrouping.slots(
            items: [.single(partner), .single(foreign)],
            collapsedKeys: []
        )
        XCTAssertEqual(
            snapped(
                flat.count, slots: flat, moving: [incoming], origin: key,
                originOf: { [partner, incoming].contains($0) ? key : nil }
            ),
            1,
            "Der Chat bildet mit seinem Partner eine Gruppe — die Linie muss dort stehen"
        )
    }

    /// Gegenprobe: Bewegt sich die GANZE Herkunft, gibt es keinen Anker, der
    /// klemmen könnte — die Gruppe darf überall hin.
    func testWholeOriginMovesFreely() {
        let expanded = slots(collapsed: false)
        XCTAssertEqual(
            snapped(expanded.count, slots: expanded, moving: [a, b, c], origin: groupKey),
            expanded.count
        )
    }

    // MARK: - Ganze Kette: Snap → Auflösung → Reorder
    //
    // Die Einzelschritte können je für sich stimmen und die Kombination
    // trotzdem falsch sein: Löst die Slot-Grenze auf eine ID auf, die selbst
    // mitwandert, macht der Reorder stillschweigend gar nichts.

    /// Simuliert den Drop-Pfad der View vollständig.
    private func drop(
        rawIndex: Int,
        order: [UUID],
        slots: [AgentTabStripSlot],
        moving: Set<UUID>,
        origin: AgentTabGroupingKey?,
        originOf: ((UUID) -> AgentTabGroupingKey?)? = nil
    ) -> [UUID] {
        let index = snapped(
            rawIndex, slots: slots, moving: moving, origin: origin, originOf: originOf
        )
        let beforeID = AgentTabGrouping.dropTargetID(
            atSlotIndex: index, in: slots, movingIDs: moving
        )
        return TabOrderReorder.newOrder(order, moving: moving, before: beforeID)
    }

    /// Nicht zusammenhängende Auswahl A+C aus [A,B,C] ans Gruppenende: Die
    /// erlaubte Grenze liegt zwangsläufig an C — also an einem bewegten Tab.
    /// Ohne Überspringen wäre der Drop ein stiller No-op.
    func testNonContiguousSelectionInsideGroupActuallyMoves() {
        let expanded = slots(collapsed: false)
        XCTAssertEqual(
            drop(
                rawIndex: 3, order: [a, b, c, foreign, trailing],
                slots: expanded, moving: [a, c], origin: groupKey
            ),
            [b, a, c, foreign, trailing],
            "Auswahl muss hinter B landen, statt unverändert zu bleiben"
        )
    }

    func testNonContiguousSelectionCanMoveToGroupStart() {
        let expanded = slots(collapsed: false)
        XCTAssertEqual(
            drop(
                rawIndex: 0, order: [a, b, c, foreign, trailing],
                slots: expanded, moving: [b], origin: groupKey
            ),
            [b, a, c, foreign, trailing]
        )
    }

    /// Ein echter Selbst-Drop bleibt ein No-op — das Überspringen darf keine
    /// Bewegung erfinden, wo keine gewollt ist.
    func testDroppingSingleTabOnItselfStaysNoOp() {
        let expanded = slots(collapsed: false)
        XCTAssertEqual(
            drop(
                rawIndex: 1, order: [a, b, c, foreign, trailing],
                slots: expanded, moving: [a], origin: groupKey
            ),
            [a, b, c, foreign, trailing]
        )
    }

    func testDropTargetSkipsMovingSlotsAndFallsBackToEnd() {
        let expanded = slots(collapsed: false)
        // Ab Slot 3 wandert alles mit → kein stationäres Ziel mehr → ans Ende.
        XCTAssertNil(
            AgentTabGrouping.dropTargetID(
                atSlotIndex: 3, in: expanded, movingIDs: [foreign, trailing]
            )
        )
    }

    // MARK: - Gruppierung aus

    func testUngroupedAllowsEveryBoundary() {
        let flat = AgentTabGrouping.slots(
            items: [a, b, foreign].map(AgentTabGroupingItem.single),
            collapsedKeys: []
        )
        for index in 0...flat.count {
            XCTAssertEqual(
                snapped(index, slots: flat, moving: [a], origin: groupKey, grouping: false),
                index
            )
        }
    }

    func testOutOfRangeIndicesAreClamped() {
        let expanded = slots(collapsed: false)
        XCTAssertEqual(snapped(-5, slots: expanded, moving: [foreign]), 0)
        XCTAssertEqual(snapped(99, slots: expanded, moving: [foreign]), expanded.count)
    }
}
