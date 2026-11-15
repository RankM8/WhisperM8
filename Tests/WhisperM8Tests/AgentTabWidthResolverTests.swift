import XCTest
@testable import WhisperM8

/// Tabs 1 „Schrumpfen“ (WM8-80, Paket 5): gleiche Breiten bis 100 pt, dann
/// klappen Gruppen ohne den aktiven Tab selbst zu (größte zuerst), dann
/// schmal bis 64 pt mit Kurztitel, erst danach Scrollen.
final class AgentTabWidthResolverTests: XCTestCase {
    private typealias R = AgentTabWidthResolver
    private let chip: CGFloat = 60
    private let wsA = AgentTabGroupingKey.workspace(UUID())
    private let wsB = AgentTabGroupingKey.workspace(UUID())

    private func ids(_ count: Int) -> [UUID] { (0..<count).map { _ in UUID() } }

    private func layout(
        _ items: [AgentTabGroupingItem],
        width: CGFloat,
        selected: UUID?,
        collapsed: Set<AgentTabGroupingKey> = [],
        opened: Set<AgentTabGroupingKey> = [],
        protected: Set<UUID> = []
    ) -> R.Layout {
        R.layout(items: items, viewportWidth: width, selectedID: selected,
                 manuallyCollapsed: collapsed, manuallyOpened: opened,
                 protectedIDs: protected, chipWidth: { _ in self.chip })
    }

    func testPlentyOfRoomGivesEveryTabTheMaximum() {
        let tabs = ids(3)
        let result = layout(tabs.map { .single($0) }, width: 2_000, selected: tabs[1])
        XCTAssertEqual(Set(result.widthByID.values), [R.maxWidth])
        XCTAssertTrue(result.autoCollapsedKeys.isEmpty)
        XCTAssertTrue(result.narrowIDs.isEmpty)
        XCTAssertEqual(result.contentWidth, 16 + 6 * 2 + 3 * 190)
    }

    func testTabsShareTheRoomEvenlyAndActiveKeepsAtLeast140() {
        let tabs = ids(6)
        // 16 Rand + 5 × 6 Abstand = 46; bleiben 720 → 120 je Tab.
        let result = layout(tabs.map { .single($0) }, width: 766, selected: tabs[0])
        XCTAssertEqual(result.widthByID[tabs[0]], 140)
        XCTAssertEqual(result.widthByID[tabs[1]], 116)
        XCTAssertTrue(result.narrowIDs.isEmpty)
    }

    func testLargestGroupWithoutActiveTabCollapsesFirst() {
        let small = ids(2), big = ids(4), solo = UUID()
        let items: [AgentTabGroupingItem] = [
            .single(solo), .group(key: wsA, sessionIDs: small), .group(key: wsB, sessionIDs: big),
        ]
        // 7 Tabs passen nicht zu je 100 pt, nach dem Zuklappen von B (4) schon.
        let result = layout(items, width: 16 + 12 + 120 + 600, selected: solo)
        XCTAssertEqual(result.autoCollapsedKeys, [wsB])
        XCTAssertNil(result.widthByID[big[0]], "zugeklappte Mitglieder haben keinen Platz")
        XCTAssertGreaterThanOrEqual(result.widthByID[small[0]] ?? 0, R.minWidth)
    }

    func testGroupWithActiveTabNeverCollapsesByItself() {
        let group = ids(5), solo = ids(2)
        let items: [AgentTabGroupingItem] = [.group(key: wsA, sessionIDs: group)] + solo.map { .single($0) }
        let result = layout(items, width: 500, selected: group[2])
        XCTAssertTrue(result.autoCollapsedKeys.isEmpty)
        XCTAssertFalse(result.narrowIDs.isEmpty, "dann bleibt nur Schmalwerden")
    }

    func testManuallyOpenedAndManuallyCollapsedGroupsAreLeftAlone() {
        let a = ids(3), b = ids(3), solo = UUID()
        let items: [AgentTabGroupingItem] = [
            .single(solo), .group(key: wsA, sessionIDs: a), .group(key: wsB, sessionIDs: b),
        ]
        let result = layout(items, width: 500, selected: solo, collapsed: [wsB], opened: [wsA])
        XCTAssertTrue(result.autoCollapsedKeys.isEmpty)
        XCTAssertNotNil(result.widthByID[a[0]], "von Hand geöffnet bleibt offen")
        XCTAssertNil(result.widthByID[b[0]], "von Hand zu bleibt zu")
    }

    func testGroupWithMultiSelectedTabDoesNotCollapseByItself() {
        let group = ids(4), solo = UUID()
        let items: [AgentTabGroupingItem] = [.single(solo), .group(key: wsA, sessionIDs: group)]
        let result = layout(items, width: 400, selected: solo, protected: [group[1]])
        XCTAssertTrue(result.autoCollapsedKeys.isEmpty)
    }

    func testNarrowTabsStopAt64AndThenTheStripScrolls() {
        let tabs = ids(20)
        let result = layout(tabs.map { .single($0) }, width: 600, selected: tabs[0])
        XCTAssertEqual(result.widthByID[tabs[0]], R.activeMinWidth)
        XCTAssertEqual(result.widthByID[tabs[1]], R.narrowMinWidth)
        XCTAssertEqual(result.narrowIDs.count, 19)
        XCTAssertFalse(result.narrowIDs.contains(tabs[0]), "der aktive Tab bleibt breit")
        XCTAssertGreaterThan(result.contentWidth, 600)
    }

    func testBetween64And100TabsAreNarrowButFit() {
        let tabs = ids(8)
        // 16 + 7 × 6 = 58; 140 aktiv; bleiben 7 × 80.
        let result = layout(tabs.map { .single($0) }, width: 58 + 140 + 560, selected: tabs[0])
        XCTAssertEqual(result.widthByID[tabs[3]], 80)
        XCTAssertEqual(result.narrowIDs.count, 7)
        XCTAssertLessThanOrEqual(result.contentWidth, 58 + 140 + 560 + 0.5)
    }

    func testNoTabsGiveAnEmptyLayout() {
        let result = layout([], width: 800, selected: nil)
        XCTAssertTrue(result.widthByID.isEmpty)
    }

    func testShortTitles() {
        XCTAssertEqual(R.shortTitle("WM8-69 Gus · Limit: Chats erkennen"), "Gus")
        XCTAssertEqual(R.shortTitle("2 Pia · Linear: Feedback"), "Pia")
        XCTAssertEqual(R.shortTitle("Jarvis: Supervisor WhisperM8"), "Jarvis")
        XCTAssertEqual(R.shortTitle("Claude Chat"), "Claude")
        XCTAssertEqual(R.shortTitle("Ole · Terminal-Tab"), "Ole")
        XCTAssertEqual(R.shortTitle(""), "")
    }
}
