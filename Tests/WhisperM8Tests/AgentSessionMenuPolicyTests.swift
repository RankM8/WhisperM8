import XCTest
@testable import WhisperM8

/// Tests für die pure Kontextmenü-Policy — die Sichtbarkeitsregeln der
/// vereinheitlichten Session-Menüs (docs/plans/kontextmenu-vereinheitlichung.md).
final class AgentSessionMenuPolicyTests: XCTestCase {
    private let defaultTraits = SessionMenuTraits()

    // MARK: - Kern-Invarianten über alle Kontexte

    func testHeaderMenuIstStriktSingulaer() {
        // Entscheidung 2026-07-15: Einzelansicht wirkt nie auf die Gruppe —
        // auch nicht bei der Tab-Farbe.
        let plan = SessionMenuPolicy.plan(for: .headerMenu, traits: defaultTraits)
        XCTAssertFalse(plan.allowsBulk)
    }

    func testBulkNurInTabUndSidebarKontexten() {
        XCTAssertTrue(SessionMenuPolicy.plan(for: .tab, traits: defaultTraits).allowsBulk)
        XCTAssertTrue(SessionMenuPolicy.plan(for: .sidebarRow, traits: defaultTraits).allowsBulk)
        XCTAssertTrue(SessionMenuPolicy.plan(for: .workspaceRow, traits: defaultTraits).allowsBulk)
        XCTAssertFalse(SessionMenuPolicy.plan(for: .gridPane, traits: defaultTraits).allowsBulk)
        XCTAssertFalse(SessionMenuPolicy.plan(for: .subagentChild, traits: defaultTraits).allowsBulk)
    }

    func testBackgroundSektionNurFuerBackgroundChats() {
        for context in SessionMenuContext.allCases {
            XCTAssertFalse(
                SessionMenuPolicy.plan(for: context, traits: defaultTraits).showsBackground,
                "\(context): Background-Sektion ohne Background-Chat"
            )
            let bg = SessionMenuTraits(isBackgroundChat: true)
            XCTAssertTrue(
                SessionMenuPolicy.plan(for: context, traits: bg).showsBackground,
                "\(context): Background-Sektion fehlt für Background-Chat"
            )
        }
    }

    func testRuntimeFolgtSupportsRuntime() {
        // Subagent-Jobs ohne Übernahme haben keine Start/Restart-Semantik.
        let noRuntime = SessionMenuTraits(supportsRuntime: false)
        for context in SessionMenuContext.allCases where context != .subagentChild {
            XCTAssertFalse(
                SessionMenuPolicy.plan(for: context, traits: noRuntime).showsRuntime,
                "\(context): Runtime trotz supportsRuntime == false"
            )
            XCTAssertTrue(
                SessionMenuPolicy.plan(for: context, traits: defaultTraits).showsRuntime,
                "\(context): Runtime-Sektion fehlt (Entscheidung: überall)"
            )
        }
    }

    // MARK: - Tab schließen / In neues Fenster (nur bei offenem Tab)

    func testCloseTabInTabKontextenImmerInSidebarNurBeiOffenemTab() {
        XCTAssertTrue(SessionMenuPolicy.plan(for: .tab, traits: defaultTraits).showsCloseTab)
        XCTAssertTrue(SessionMenuPolicy.plan(for: .headerMenu, traits: defaultTraits).showsCloseTab)

        for context: SessionMenuContext in [.sidebarRow, .workspaceRow] {
            XCTAssertFalse(
                SessionMenuPolicy.plan(for: context, traits: defaultTraits).showsCloseTab,
                "\(context): Tab schließen ohne offenen Tab"
            )
            let open = SessionMenuTraits(isTabOpen: true)
            XCTAssertTrue(
                SessionMenuPolicy.plan(for: context, traits: open).showsCloseTab,
                "\(context): Tab schließen fehlt bei offenem Tab"
            )
        }
        // Grid-Pane bewusst nie (⊖ leert nur den Slot).
        let open = SessionMenuTraits(isTabOpen: true)
        XCTAssertFalse(SessionMenuPolicy.plan(for: .gridPane, traits: open).showsCloseTab)
        XCTAssertFalse(SessionMenuPolicy.plan(for: .subagentChild, traits: open).showsCloseTab)
    }

    func testWindowMoveBrauchtOffenenTabAusserhalbDerTabKontexte() {
        XCTAssertTrue(SessionMenuPolicy.plan(for: .tab, traits: defaultTraits).showsWindowMove)
        XCTAssertTrue(SessionMenuPolicy.plan(for: .headerMenu, traits: defaultTraits).showsWindowMove)
        for context: SessionMenuContext in [.sidebarRow, .workspaceRow, .gridPane] {
            XCTAssertFalse(
                SessionMenuPolicy.plan(for: context, traits: defaultTraits).showsWindowMove,
                "\(context): Fenster-Verschieben ohne offenen Tab"
            )
            let open = SessionMenuTraits(isTabOpen: true)
            XCTAssertTrue(
                SessionMenuPolicy.plan(for: context, traits: open).showsWindowMove,
                "\(context): Fenster-Verschieben fehlt bei offenem Tab"
            )
        }
    }

    // MARK: - Workspace-Kontexte

    func testWorkspaceKontexteZeigenEntfernenKopfOhneMembershipDuplikat() {
        // Review-Finding aus der Workspace-Zeile: der Entfernen-Eintrag der
        // eigenen Gruppe steht als Kopf — das Mitgliedschaftsmenü darf ihn
        // nicht duplizieren.
        for context: SessionMenuContext in [.workspaceRow, .gridPane] {
            let plan = SessionMenuPolicy.plan(for: context, traits: defaultTraits)
            XCTAssertTrue(plan.showsWorkspaceRemovalHead, "\(context)")
            XCTAssertFalse(plan.includesMembershipRemoval, "\(context)")
        }
        for context: SessionMenuContext in [.tab, .headerMenu, .sidebarRow] {
            let plan = SessionMenuPolicy.plan(for: context, traits: defaultTraits)
            XCTAssertFalse(plan.showsWorkspaceRemovalHead, "\(context)")
            XCTAssertTrue(plan.includesMembershipRemoval, "\(context)")
        }
    }

    func testMaximierenNurAmGridPane() {
        for context in SessionMenuContext.allCases {
            XCTAssertEqual(
                SessionMenuPolicy.plan(for: context, traits: defaultTraits).showsMaximize,
                context == .gridPane,
                "\(context)"
            )
        }
    }

    // MARK: - Subagent-Kind (Entscheidung: reduziert erweitert)

    func testSubagentKindIstReduziert() {
        let plan = SessionMenuPolicy.plan(for: .subagentChild, traits: defaultTraits)
        XCTAssertFalse(plan.showsAutoTitle)
        XCTAssertFalse(plan.showsManagement)
        XCTAssertFalse(plan.showsWindowWorkspace)
        XCTAssertFalse(plan.showsAppearance)
        XCTAssertFalse(plan.showsRuntime)
        XCTAssertFalse(plan.showsSubagentStop)
    }

    func testSubagentKindZeigtJobStopNurWennStoppbar() {
        let running = SessionMenuTraits(canStopSubagentJob: true)
        XCTAssertTrue(SessionMenuPolicy.plan(for: .subagentChild, traits: running).showsSubagentStop)
        // Andere Kontexte zeigen den Job-Stop nicht (Subagent-Tabs haben
        // eigene Controls in der Detail-View).
        for context in SessionMenuContext.allCases where context != .subagentChild {
            XCTAssertFalse(
                SessionMenuPolicy.plan(for: context, traits: running).showsSubagentStop,
                "\(context)"
            )
        }
    }

    // MARK: - Vollkontexte zeigen alle Verwaltungs-Sektionen

    func testVollKontexteZeigenManagementWorkspaceUndAppearance() {
        for context: SessionMenuContext in [.tab, .headerMenu, .sidebarRow, .workspaceRow, .gridPane] {
            let plan = SessionMenuPolicy.plan(for: context, traits: defaultTraits)
            XCTAssertTrue(plan.showsAutoTitle, "\(context)")
            XCTAssertTrue(plan.showsManagement, "\(context)")
            XCTAssertTrue(plan.showsWindowWorkspace, "\(context)")
            XCTAssertTrue(plan.showsAppearance, "\(context)")
        }
    }
}
