import XCTest
@testable import WhisperM8

final class NotchStatusModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func input(
        _ title: String,
        _ status: AgentSessionRuntimeStatus?,
        since: TimeInterval? = nil,
        lastTurnAgo: TimeInterval? = nil,
        project: String? = "proj"
    ) -> NotchChatInput {
        NotchChatInput(
            id: UUID(), title: title, project: project, status: status,
            statusSince: since.map { now.addingTimeInterval(-$0) },
            lastTurnAt: lastTurnAgo.map { now.addingTimeInterval(-$0) },
            lastActivityAt: now.addingTimeInterval(-3_600),
            activity: nil)
    }

    // MARK: Sortierung

    func testRowsAreSortedByAttention() {
        let inputs = [
            input("ready", .idle, since: 4_000),
            input("working", .working, since: 60),
            input("fresh", .idle, since: 120, lastTurnAgo: 120),
            input("errored", .errored, since: 30),
            input("waiting", .awaitingInput, since: 10),
        ]
        let rows = NotchStatusModel.rows(from: inputs, now: now, showFreshDone: true)
        XCTAssertEqual(rows.map(\.title), ["waiting", "errored", "fresh", "working", "ready"])
    }

    func testWithinRankNewestStatusChangeComesFirst() {
        let inputs = [
            input("old", .working, since: 600),
            input("new", .working, since: 5),
        ]
        let rows = NotchStatusModel.rows(from: inputs, now: now, showFreshDone: true)
        XCTAssertEqual(rows.map(\.title), ["new", "old"])
    }

    func testStoppedAndUnknownChatsAreDropped() {
        let inputs = [input("a", .stopped), input("b", nil), input("c", .working, since: 1)]
        let rows = NotchStatusModel.rows(from: inputs, now: now, showFreshDone: true)
        XCTAssertEqual(rows.map(\.title), ["c"])
    }

    func testFreshDoneExpiresAfterTheSharedWindow() {
        let window = AttentionModelBuilder.freshDoneWindow
        let inside = input("inside", .idle, lastTurnAgo: window - 1)
        let outside = input("outside", .idle, lastTurnAgo: window + 1)
        let rows = NotchStatusModel.rows(from: [inside, outside], now: now, showFreshDone: true)
        XCTAssertEqual(rows.first { $0.title == "inside" }?.category, .freshDone)
        XCTAssertEqual(rows.first { $0.title == "outside" }?.category, .idle)
    }

    func testFreshDoneSwitchTurnsThemIntoReady() {
        let rows = NotchStatusModel.rows(
            from: [input("fresh", .idle, lastTurnAgo: 30)], now: now, showFreshDone: false)
        XCTAssertEqual(rows.first?.category, .idle)
        XCTAssertEqual(rows.first?.rank, 5)
    }

    func testClassificationMatchesTheCLIBuilder() {
        // Gleiche Rang-Logik wie `whisperm8 chats`: ein Fall pro Kategorie.
        let cases: [(AgentSessionRuntimeStatus?, TimeInterval?, ChatsAttentionCategory, Int)] = [
            (.awaitingInput, nil, .needsYou, 1),
            (.errored, nil, .needsYou, 2),
            (.idle, 60, .freshDone, 3),
            (.working, nil, .working, 4),
            (.idle, 99_999, .idle, 5),
            (.stopped, nil, .idle, 5),
        ]
        for (status, turnAgo, category, rank) in cases {
            let result = AttentionModelBuilder.classify(
                status: status, lastTurnAt: turnAgo.map { now.addingTimeInterval(-$0) }, since: nil, now: now)
            XCTAssertEqual(result.0, category)
            XCTAssertEqual(result.1, rank)
        }
    }

    // MARK: Zähler und Abschnitte

    func testSummaryCountsEachKind() {
        let rows = NotchStatusModel.rows(from: [
            input("w1", .working, since: 1), input("w2", .working, since: 2),
            input("a", .awaitingInput, since: 3), input("e", .errored, since: 4),
            input("f", .idle, since: 5, lastTurnAgo: 5), input("r", .idle, since: 99_999),
        ], now: now, showFreshDone: true)
        let summary = NotchStatusModel.summary(of: rows)
        XCTAssertEqual(summary.working, 2)
        XCTAssertEqual(summary.waiting, 1)
        XCTAssertEqual(summary.errored, 1)
        XCTAssertEqual(summary.freshDone, 1)
        XCTAssertEqual(summary.idle, 1)
        XCTAssertEqual(summary.needsYou, 2)
        XCTAssertEqual(summary.chipCount, 4)
    }

    func testOnlyReadyChatsDoNotShowTheStrip() {
        let rows = NotchStatusModel.rows(from: [input("r", .idle, since: 99_999)], now: now, showFreshDone: true)
        let summary = NotchStatusModel.summary(of: rows)
        XCTAssertFalse(summary.hasActivity)
        XCTAssertFalse(NotchStatusModel.isVisible(summary: summary, isExpanded: false, alert: nil))
        XCTAssertTrue(NotchStatusModel.isVisible(summary: summary, isExpanded: true, alert: nil))
    }

    func testAnyAlertMakesTheStripVisible() {
        let alert = NotchAlert(sessionID: UUID(), title: "x", kind: .awaitingInput)
        XCTAssertTrue(NotchStatusModel.isVisible(summary: .empty, isExpanded: false, alert: alert))
    }

    func testSectionsFollowAttentionOrderAndSkipEmpty() {
        let rows = NotchStatusModel.rows(from: [
            input("w", .working, since: 1), input("a", .awaitingInput, since: 2), input("r", .idle, since: 99_999),
        ], now: now, showFreshDone: true)
        let sections = NotchStatusModel.sections(of: rows)
        XCTAssertEqual(sections.map(\.kind), [.needsYou, .working, .ready])
    }

    func testRowHeadlineUsesTabSwitcherWords() {
        let rows = NotchStatusModel.rows(from: [input("w", .working, since: 125)], now: now, showFreshDone: true)
        XCTAssertEqual(rows.first?.headline, "\(AgentStatusAccessibility.label(for: .working) ?? "") · 2 min")
    }

    func testNextFreshDoneExpiryPicksTheEarliest() {
        let window = AttentionModelBuilder.freshDoneWindow
        let a = input("a", .idle, lastTurnAgo: 60)
        let b = input("b", .idle, lastTurnAgo: 300)
        let expiry = NotchStatusModel.nextFreshDoneExpiry(in: [a, b], now: now)
        XCTAssertEqual(expiry, now.addingTimeInterval(-300 + window))
        XCTAssertNil(NotchStatusModel.nextFreshDoneExpiry(in: [input("w", .working)], now: now))
        XCTAssertNil(NotchStatusModel.nextFreshDoneExpiry(in: [input("old", .idle, lastTurnAgo: window + 10)], now: now))
    }

    // MARK: Eingaben aus dem Workspace

    func testInputBuilderSkipsArchivedSubagentAndUnknownChats() {
        let project = AgentProject(name: "whisperm8", path: "/tmp/x")
        let live = AgentChatSession(provider: .claude, projectID: project.id, title: "Live")
        let archived = AgentChatSession(
            provider: .claude, projectID: project.id, title: "Archiv", status: .archived, archivedAt: now)
        let job = AgentChatSession(
            provider: .codex, projectID: project.id, title: "Job", kind: .subagentJob)
        let noStatus = AgentChatSession(provider: .claude, projectID: project.id, title: "Ohne")
        let workspace = AgentWorkspace(projects: [project], sessions: [live, archived, job, noStatus])
        let statuses: [UUID: AgentSessionRuntimeStatus] = [
            live.id: .working, archived.id: .working, job.id: .working,
        ]
        let inputs = NotchInputBuilder.inputs(
            statuses: statuses, workspace: workspace, statusSince: { _ in self.now }, activity: nil)
        XCTAssertEqual(inputs.map(\.title), ["Live"])
        XCTAssertEqual(inputs.first?.project, "whisperm8")
        XCTAssertEqual(inputs.first?.statusSince, now)
    }

    func testInputBuilderOnlyReadsActivityWhenAsked() {
        let project = AgentProject(name: "p", path: "/tmp/x")
        let session = AgentChatSession(provider: .claude, projectID: project.id, title: "T")
        let workspace = AgentWorkspace(projects: [project], sessions: [session])
        var reads = 0
        let off = NotchInputBuilder.inputs(
            statuses: [session.id: .working], workspace: workspace, statusSince: { _ in nil }, activity: nil)
        XCTAssertNil(off.first?.activity)
        let on = NotchInputBuilder.inputs(
            statuses: [session.id: .working], workspace: workspace, statusSince: { _ in nil },
            activity: { _ in reads += 1; return AgentSessionActivity(detail: .tool(name: "Edit", argument: "a.swift")) })
        XCTAssertEqual(reads, 1)
        XCTAssertNotNil(on.first?.activity)
    }
}

final class NotchAlertTrackerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let a = UUID()
    private let b = UUID()

    private func ingest(
        _ tracker: inout NotchAlertTracker,
        _ statuses: [UUID: AgentSessionRuntimeStatus],
        showFreshDone: Bool = true,
        appIsActive: Bool = false,
        at offset: TimeInterval = 0
    ) -> NotchAlert? {
        tracker.ingest(
            statuses: statuses, titles: [a: "Alpha", b: "Beta"], showFreshDone: showFreshDone,
            appIsActive: appIsActive, now: now.addingTimeInterval(offset))
    }

    func testFirstSnapshotIsOnlyTheBaseline() {
        var tracker = NotchAlertTracker()
        XCTAssertNil(ingest(&tracker, [a: .awaitingInput]))
        XCTAssertNil(ingest(&tracker, [a: .awaitingInput], at: 1))
    }

    func testTransitionToAwaitingInputFires() {
        var tracker = NotchAlertTracker()
        _ = ingest(&tracker, [a: .working])
        let alert = ingest(&tracker, [a: .awaitingInput], at: 1)
        XCTAssertEqual(alert, NotchAlert(sessionID: a, title: "Alpha", kind: .awaitingInput))
    }

    func testNewChatThatStartsAwaitingFires() {
        var tracker = NotchAlertTracker()
        _ = ingest(&tracker, [:])
        XCTAssertEqual(ingest(&tracker, [a: .awaitingInput], at: 1)?.kind, .awaitingInput)
    }

    func testErrorFires() {
        var tracker = NotchAlertTracker()
        _ = ingest(&tracker, [a: .working])
        XCTAssertEqual(ingest(&tracker, [a: .errored], at: 1)?.kind, .errored)
    }

    func testFinishedNeedsWorkingBefore() {
        var tracker = NotchAlertTracker()
        _ = ingest(&tracker, [a: .awaitingInput, b: .working])
        // awaiting → idle ist nicht „fertig", working → idle schon.
        let alert = ingest(&tracker, [a: .idle, b: .idle], at: 1)
        XCTAssertEqual(alert?.sessionID, b)
        XCTAssertEqual(alert?.kind, .finished)
        XCTAssertEqual(alert?.extraCount, 0)
    }

    func testFinishedIsSuppressedWhenSwitchIsOffOrAppIsActive() {
        var off = NotchAlertTracker()
        _ = ingest(&off, [a: .working], showFreshDone: false)
        XCTAssertNil(ingest(&off, [a: .idle], showFreshDone: false, at: 1))

        var active = NotchAlertTracker()
        _ = ingest(&active, [a: .working], appIsActive: true)
        XCTAssertNil(ingest(&active, [a: .idle], appIsActive: true, at: 1))
    }

    func testAwaitingStillFiresWhileAppIsActive() {
        var tracker = NotchAlertTracker()
        _ = ingest(&tracker, [a: .working], appIsActive: true)
        XCTAssertEqual(ingest(&tracker, [a: .awaitingInput], appIsActive: true, at: 1)?.kind, .awaitingInput)
    }

    func testSimultaneousEventsPickTheMostUrgentAndCountTheRest() {
        var tracker = NotchAlertTracker()
        _ = ingest(&tracker, [a: .working, b: .working])
        let alert = ingest(&tracker, [a: .idle, b: .errored], at: 1)
        XCTAssertEqual(alert?.sessionID, b)
        XCTAssertEqual(alert?.kind, .errored)
        XCTAssertEqual(alert?.extraCount, 1)
    }

    func testCooldownThrottlesFlappingStatus() {
        var tracker = NotchAlertTracker()
        _ = ingest(&tracker, [a: .working])
        XCTAssertNotNil(ingest(&tracker, [a: .awaitingInput], at: 1))
        _ = ingest(&tracker, [a: .working], at: 2)
        // Zurück nach „wartet" innerhalb der Abkühlzeit: still.
        XCTAssertNil(ingest(&tracker, [a: .awaitingInput], at: 3))
        _ = ingest(&tracker, [a: .working], at: 4)
        // Nach der Abkühlzeit wieder wach.
        XCTAssertNotNil(ingest(&tracker, [a: .awaitingInput], at: 1 + NotchAlertTracker.cooldown + 1))
    }

    func testResetDropsTheBaseline() {
        var tracker = NotchAlertTracker()
        _ = ingest(&tracker, [a: .working])
        tracker.reset()
        XCTAssertNil(ingest(&tracker, [a: .awaitingInput], at: 1))
    }
}

final class NotchGeometryTests: XCTestCase {
    /// 14-Zoll-MacBook-Pro: Notch ca. 185 pt breit, Menüleiste 38 pt.
    private func notchScreen(id: UInt32 = 1, builtIn: Bool = true) -> NotchScreenInfo {
        NotchScreenInfo(
            displayID: id,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            safeAreaTop: 38,
            auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5,
            isBuiltIn: builtIn)
    }

    private func plainScreen(id: UInt32, builtIn: Bool = false, x: CGFloat = 1512) -> NotchScreenInfo {
        NotchScreenInfo(
            displayID: id,
            frame: CGRect(x: x, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: x, y: 0, width: 2560, height: 1415),
            safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, isBuiltIn: builtIn)
    }

    func testNotchDetectionAndWidth() {
        let screen = notchScreen()
        XCTAssertTrue(screen.hasNotch)
        XCTAssertEqual(screen.notchWidth, 185, accuracy: 0.001)
        XCTAssertEqual(screen.notchCenterX, 756, accuracy: 0.001)
        XCTAssertFalse(plainScreen(id: 2).hasNotch)
        XCTAssertEqual(plainScreen(id: 2).notchWidth, 0)
    }

    func testSafeAreaAloneIsNotEnough() {
        var screen = notchScreen()
        screen.auxiliaryLeftWidth = nil
        XCTAssertFalse(screen.hasNotch)
    }

    func testScreenChoiceAutoPrefersBuiltInNotchScreen() {
        let screens = [plainScreen(id: 2), notchScreen()]
        XCTAssertEqual(NotchGeometry.selectScreen(choice: .auto, screens: screens, mainDisplayID: 2)?.displayID, 1)
    }

    func testScreenChoiceAutoFallsBackToMain() {
        let screens = [plainScreen(id: 2), plainScreen(id: 3, x: 4000)]
        XCTAssertEqual(NotchGeometry.selectScreen(choice: .auto, screens: screens, mainDisplayID: 3)?.displayID, 3)
    }

    func testScreenChoiceExplicit() {
        let screens = [plainScreen(id: 2), notchScreen()]
        XCTAssertEqual(NotchGeometry.selectScreen(choice: .main, screens: screens, mainDisplayID: 2)?.displayID, 2)
        XCTAssertEqual(NotchGeometry.selectScreen(choice: .builtIn, screens: screens, mainDisplayID: 2)?.displayID, 1)
        // Kein eingebauter Bildschirm: Hauptbildschirm.
        XCTAssertEqual(
            NotchGeometry.selectScreen(choice: .builtIn, screens: [plainScreen(id: 2)], mainDisplayID: 2)?.displayID, 2)
        XCTAssertNil(NotchGeometry.selectScreen(choice: .auto, screens: [], mainDisplayID: nil))
    }

    func testNotchCompactFrameHangsFlushAtTheTopAroundTheNotch() {
        let screen = notchScreen()
        let frame = NotchGeometry.panelFrame(screen: screen, mode: .compact(chipCount: 2))
        XCTAssertEqual(frame.maxY, screen.frame.maxY)
        XCTAssertEqual(frame.height, 38)
        XCTAssertEqual(frame.midX, screen.notchCenterX, accuracy: 0.001)
        XCTAssertEqual(frame.width, 185 + 2 * NotchGeometry.compactWing, accuracy: 0.001)
    }

    func testNotchAlertIsWiderThanCompact() {
        let screen = notchScreen()
        let compact = NotchGeometry.panelFrame(screen: screen, mode: .compact(chipCount: 1))
        let alert = NotchGeometry.panelFrame(screen: screen, mode: .alert)
        XCTAssertGreaterThan(alert.width, compact.width)
        XCTAssertEqual(alert.midX, compact.midX, accuracy: 0.001)
    }

    func testNotchExpandedGrowsDownwardAndKeepsTheTopEdge() {
        let screen = notchScreen()
        let small = NotchGeometry.panelFrame(screen: screen, mode: .expanded(rowCount: 1, sectionCount: 1))
        let large = NotchGeometry.panelFrame(screen: screen, mode: .expanded(rowCount: 5, sectionCount: 3))
        XCTAssertEqual(small.maxY, screen.frame.maxY)
        XCTAssertEqual(large.maxY, screen.frame.maxY)
        XCTAssertGreaterThan(large.height, small.height)
        XCTAssertGreaterThanOrEqual(small.width, NotchGeometry.expandedMinWidth)
    }

    func testExpandedListHeightIsCapped() {
        let huge = NotchGeometry.listHeight(rowCount: 100, sectionCount: 4)
        XCTAssertEqual(
            huge, NotchGeometry.expandedMaxListHeight + NotchGeometry.footerHeight + NotchGeometry.listPadding)
    }

    func testPillSitsCenteredBelowTheMenuBar() {
        let screen = plainScreen(id: 2)
        let frame = NotchGeometry.panelFrame(screen: screen, mode: .compact(chipCount: 2))
        XCTAssertEqual(frame.midX, screen.frame.midX, accuracy: 0.001)
        // Menüleiste 25 pt + Abstand: Oberkante der Pille darunter.
        XCTAssertEqual(frame.maxY, screen.frame.maxY - 25 - NotchGeometry.pillTopGap, accuracy: 0.001)
        XCTAssertEqual(frame.height, NotchGeometry.pillHeight)
    }

    func testPillWithoutChipsStillFitsItsHint() {
        XCTAssertGreaterThan(NotchGeometry.pillCompactWidth(chipCount: 0), NotchGeometry.pillCompactWidth(chipCount: 1))
    }

    func testPillExpandedGrowsDownward() {
        let screen = plainScreen(id: 2)
        let compact = NotchGeometry.panelFrame(screen: screen, mode: .compact(chipCount: 1))
        let expanded = NotchGeometry.panelFrame(screen: screen, mode: .expanded(rowCount: 3, sectionCount: 2))
        XCTAssertEqual(expanded.maxY, compact.maxY, accuracy: 0.001)
        XCTAssertGreaterThan(expanded.height, compact.height)
    }
}

final class NotchFullscreenDetectorTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testForeignWindowCoveringTheScreenIsFullscreen() {
        let windows = [NotchWindowSample(layer: 0, bounds: screen, ownerPID: 500)]
        XCTAssertTrue(NotchFullscreenDetector.isFullscreen(screenFrameQuartz: screen, windows: windows, ownPID: 1))
    }

    func testMaximizedWindowBelowTheMenuBarIsNotFullscreen() {
        let windows = [NotchWindowSample(layer: 0, bounds: CGRect(x: 0, y: 38, width: 1512, height: 944), ownerPID: 500)]
        XCTAssertFalse(NotchFullscreenDetector.isFullscreen(screenFrameQuartz: screen, windows: windows, ownPID: 1))
    }

    func testOwnWindowsAndOtherLayersDoNotCount() {
        let windows = [
            NotchWindowSample(layer: 0, bounds: screen, ownerPID: 1),
            NotchWindowSample(layer: 25, bounds: screen, ownerPID: 500),
        ]
        XCTAssertFalse(NotchFullscreenDetector.isFullscreen(screenFrameQuartz: screen, windows: windows, ownPID: 1))
    }

    func testQuartzConversionFlipsTheYAxis() {
        // Zweiter Bildschirm rechts, bündig oben am 982 pt hohen Hauptbildschirm.
        let cocoa = CGRect(x: 1512, y: 982 - 1440, width: 2560, height: 1440)
        let quartz = NotchFullscreenDetector.quartzFrame(fromCocoa: cocoa, primaryHeight: 982)
        XCTAssertEqual(quartz, CGRect(x: 1512, y: 0, width: 2560, height: 1440))
    }
}

@MainActor
final class NotchConfigTests: XCTestCase {
    private func prefs() -> AppPreferences {
        let name = "notch-config-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return AppPreferences(defaults: defaults)
    }

    func testFeatureIsOffByDefault() {
        XCTAssertFalse(NotchConfig.current(prefs()).isActive)
    }

    func testUserSwitchActivatesIt() {
        let p = prefs()
        p.isNotchStatusEnabled = true
        XCTAssertTrue(NotchConfig.current(p).isActive)
    }

    func testKillSwitchOverridesTheUserSwitch() {
        let p = prefs()
        p.isNotchStatusEnabled = true
        p.isNotchStatusFeatureEnabled = false
        XCTAssertFalse(NotchConfig.current(p).isActive)
    }

    func testDefaultsAreCaptureHiddenFreshDoneOnAndNoHover() {
        let config = NotchConfig.current(prefs())
        XCTAssertTrue(config.hideFromCapture)
        XCTAssertTrue(config.showFreshDone)
        XCTAssertFalse(config.expandOnHover)
        XCTAssertEqual(config.screenChoice, .auto)
    }

    func testUnknownScreenValueFallsBackToAuto() {
        let p = prefs()
        p.notchStatusScreenRaw = "kaputt"
        XCTAssertEqual(NotchConfig.current(p).screenChoice, .auto)
    }
}
