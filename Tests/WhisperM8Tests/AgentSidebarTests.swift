import Combine
import Foundation
import XCTest
@testable import WhisperM8

// MARK: - Fixtures

private func makeSidebarSession(
    id: UUID = UUID(),
    projectID: UUID,
    title: String = "Chat",
    provider: AgentProvider = .claude,
    status: AgentChatStatus = .closed,
    createdManually: Bool? = true,
    lastActivityAt: Date = Date(timeIntervalSince1970: 1_000),
    groupName: String? = nil
) -> AgentChatSession {
    var session = AgentChatSession(
        id: id,
        provider: provider,
        projectID: projectID,
        title: title,
        createdAt: Date(timeIntervalSince1970: 500),
        lastActivityAt: lastActivityAt,
        createdManually: createdManually
    )
    session.status = status
    session.groupName = groupName
    return session
}

// MARK: - Per-Item-Status-Publisher (P4 S2)

@MainActor
final class RuntimeStatusPublisherTests: XCTestCase {
    func testPublisherEmitsInitialValueOnSubscribe() {
        let store = AgentSessionRuntimeStatusStore()
        let sessionID = UUID()
        store.setStatus(.working, for: sessionID)

        var received: [AgentSessionRuntimeStatus?] = []
        let cancellable = store.statusPublisher(for: sessionID)
            .sink { received.append($0) }
        defer { cancellable.cancel() }

        XCTAssertEqual(received, [.working])
    }

    func testForeignSessionTicksAreFiltered() {
        let store = AgentSessionRuntimeStatusStore()
        let mine = UUID()
        let other = UUID()

        var received: [AgentSessionRuntimeStatus?] = []
        let cancellable = store.statusPublisher(for: mine)
            .sink { received.append($0) }
        defer { cancellable.cancel() }

        store.setStatus(.working, for: other)
        store.setStatus(.idle, for: other)

        // Initial nil; fremde Ticks werden von removeDuplicates geschluckt.
        XCTAssertEqual(received, [nil])
    }

    func testOwnTransitionEmitsExactlyOnce() {
        let store = AgentSessionRuntimeStatusStore()
        let mine = UUID()

        var received: [AgentSessionRuntimeStatus?] = []
        let cancellable = store.statusPublisher(for: mine)
            .sink { received.append($0) }
        defer { cancellable.cancel() }

        store.setStatus(.working, for: mine)
        store.setStatus(.working, for: mine) // Dedupe in setStatus
        store.setStatus(.idle, for: mine)

        XCTAssertEqual(received, [nil, .working, .idle])
    }
}

// MARK: - Equatable-Kontrakt der Row (P4 S3)

@MainActor
final class SessionListButtonEquatableTests: XCTestCase {
    private func makeButton(
        session: AgentChatSession,
        isSelected: Bool = false,
        isOpenTab: Bool = false,
        accentColorHex: String? = nil,
        isAutoRenaming: Bool = false,
        isMissingTranscript: Bool = false,
        isMultiSelected: Bool = false,
        indentAsSubagent: Bool = false,
        isUnreadSubagentResult: Bool = false,
        runningChildCount: Int = 0,
        erroredChildCount: Int = 0,
        unreadChildCount: Int = 0,
        store: AgentSessionRuntimeStatusStore? = nil
    ) -> SessionListButton {
        SessionListButton(
            session: session,
            isSelected: isSelected,
            isMultiSelected: isMultiSelected,
            isOpenTab: isOpenTab,
            accentColorHex: accentColorHex,
            statusStore: store ?? AgentSessionRuntimeStatusStore(),
            isAutoRenaming: isAutoRenaming,
            isMissingTranscript: isMissingTranscript,
            indentAsSubagent: indentAsSubagent,
            isUnreadSubagentResult: isUnreadSubagentResult,
            runningChildCount: runningChildCount,
            erroredChildCount: erroredChildCount,
            unreadChildCount: unreadChildCount,
            onSelect: {},
            onClose: {}
        )
    }

    func testIdenticalDataIsEqualRegardlessOfStoreAndClosures() {
        let session = makeSidebarSession(projectID: UUID())
        let a = makeButton(session: session, store: AgentSessionRuntimeStatusStore())
        let b = makeButton(session: session, store: AgentSessionRuntimeStatusStore())
        XCTAssertEqual(a, b, "Store-Referenz und Closures dürfen den Vergleich nicht beeinflussen")
    }

    func testEachDisplayRelevantFieldBreaksEquality() {
        let projectID = UUID()
        let session = makeSidebarSession(projectID: projectID)
        let base = makeButton(session: session)

        var renamed = session
        renamed.title = "Anderer Titel"
        XCTAssertNotEqual(base, makeButton(session: renamed))
        XCTAssertNotEqual(base, makeButton(session: session, isSelected: true))
        XCTAssertNotEqual(base, makeButton(session: session, isOpenTab: true))
        XCTAssertNotEqual(base, makeButton(session: session, accentColorHex: "#FF9F0A"))
        XCTAssertNotEqual(base, makeButton(session: session, isAutoRenaming: true))
        XCTAssertNotEqual(base, makeButton(session: session, isMissingTranscript: true))
        XCTAssertNotEqual(base, makeButton(session: session, isMultiSelected: true))
        // Subagent-Felder (Slice 3) — Pflegefalle: neue darstellungsrelevante
        // Felder MÜSSEN das `==` brechen, sonst bleiben Rows stale.
        XCTAssertNotEqual(base, makeButton(session: session, indentAsSubagent: true))
        XCTAssertNotEqual(base, makeButton(session: session, isUnreadSubagentResult: true))
        XCTAssertNotEqual(base, makeButton(session: session, runningChildCount: 2))
        XCTAssertNotEqual(base, makeButton(session: session, erroredChildCount: 1))
        XCTAssertNotEqual(base, makeButton(session: session, unreadChildCount: 3))
    }
}

// MARK: - SubagentRoad-Welle (B4)

/// Die Wellen-Kurve ist pur (Wanduhr rein, Opazität raus) — hier ist der
/// Kontrakt festgenagelt, der die „unabhängige Pulse"-Regression verhindert:
/// alle Balken teilen EINE Zeitbasis, Balken i ist die um i·stagger
/// verschobene Kurve von Balken 0 (Lauflicht links → rechts).
final class SubagentRoadWaveTests: XCTestCase {
    func testBarsShareOneTimebaseShiftedByStagger() {
        for time in stride(from: 0.0, through: 2.2, by: 0.05) {
            for index in 1..<6 {
                XCTAssertEqual(
                    SubagentRoad.opacity(at: time + Double(index) * SubagentRoad.stagger, index: index),
                    SubagentRoad.opacity(at: time, index: 0),
                    accuracy: 0.0001,
                    "Balken \(index) muss die verschobene Kurve von Balken 0 sein — sonst pulst er unabhängig"
                )
            }
        }
    }

    func testWaveTravelsLeftToRight() {
        // Peak von Balken 0 liegt bei 18 % des Zyklus; jeder weitere Balken
        // peakt um stagger später — das Licht wandert nach rechts.
        let peak0 = 0.18 * SubagentRoad.cycle
        for index in 0..<6 {
            let value = SubagentRoad.opacity(at: peak0 + Double(index) * SubagentRoad.stagger, index: index)
            XCTAssertEqual(value, 1.0, accuracy: 0.0001)
        }
    }

    func testOpacityStaysInBoundsIncludingNegativePhases() {
        // Frühe Zeiten machen die Phase hinterer Balken negativ — der
        // Wrap darf nie unter die Grund-Opazität fallen oder über 1 gehen.
        for step in 0..<300 {
            let value = SubagentRoad.opacity(at: Double(step) * 0.01, index: 5)
            XCTAssertGreaterThanOrEqual(value, 0.2999)
            XCTAssertLessThanOrEqual(value, 1.0001)
        }
    }
}

// MARK: - Sidebar-Modell-Builder (P4 S4)

final class AgentSidebarModelBuilderTests: XCTestCase {
    func testGroupingShowsAllManualSessionsExceptArchivedImportedAndPinned() {
        let projectID = UUID()
        let open = makeSidebarSession(projectID: projectID, title: "Offen")
        let closedTab = makeSidebarSession(projectID: projectID, title: "Zu, aber Bestand")
        let archived = makeSidebarSession(projectID: projectID, title: "Archiv", status: .archived)
        let notManual = makeSidebarSession(projectID: projectID, title: "Import", createdManually: nil)
        let pinned = makeSidebarSession(projectID: projectID, title: "Gepinnt")

        let grouped = AgentSidebarModelBuilder.sessionsByProject(
            workspaceSessions: [open, closedTab, archived, notManual, pinned],
            pinnedSessionIDs: [pinned.id]
        )

        let titles = (grouped[projectID] ?? []).map(\.title)
        XCTAssertTrue(titles.contains("Offen"))
        XCTAssertTrue(titles.contains("Zu, aber Bestand"), "Sidebar = Chat-Liste: auch Sessions ohne offenen Tab sichtbar")
        XCTAssertFalse(titles.contains("Archiv"))
        XCTAssertFalse(titles.contains("Import"))
        XCTAssertFalse(titles.contains("Gepinnt"), "Gepinnte Sessions erscheinen exklusiv in der Gepinnt-Sektion")
    }

    func testGroupingSortsLikeAgentSessionStore() {
        let projectID = UUID()
        let older = makeSidebarSession(projectID: projectID, title: "Alt", lastActivityAt: Date(timeIntervalSince1970: 100))
        let newer = makeSidebarSession(projectID: projectID, title: "Neu", lastActivityAt: Date(timeIntervalSince1970: 200))

        let grouped = AgentSidebarModelBuilder.sessionsByProject(
            workspaceSessions: [older, newer],
            pinnedSessionIDs: []
        )

        XCTAssertEqual(
            (grouped[projectID] ?? []).map(\.title),
            AgentSessionStore.sortedSessions([older, newer]).map(\.title),
            "Sortierung muss identisch zu AgentSessionStore.sortedSessions sein"
        )
    }

    func testPinnedSessionsKeepPinOrderAndDropArchivedAndUnknown() {
        let projectID = UUID()
        let first = makeSidebarSession(projectID: projectID, title: "Erster Pin")
        let second = makeSidebarSession(projectID: projectID, title: "Zweiter Pin")
        let archived = makeSidebarSession(projectID: projectID, title: "Archiv", status: .archived)

        let pinned = AgentSidebarModelBuilder.pinnedSessions(
            workspaceSessions: [second, first, archived],
            pinnedSessionIDs: [first.id, archived.id, UUID(), second.id]
        )

        XCTAssertEqual(pinned.map(\.title), ["Erster Pin", "Zweiter Pin"], "Pin-Reihenfolge, nicht Workspace-Reihenfolge")
    }

    func testSearchMatchesProjectAndSessionFields() {
        let project = AgentProject(name: "RankM8", path: "/tmp/rankm8")
        let other = AgentProject(name: "Anderes", path: "/tmp/other")
        let session = makeSidebarSession(projectID: other.id, title: "SEO-Recherche", groupName: "Marketing")
        let sessionsByProject = [other.id: [session]]

        // Leere Query → alle
        XCTAssertEqual(
            AgentSidebarModelBuilder.visibleProjects(manualProjects: [project, other], sessionsByProject: sessionsByProject, query: "  ").count,
            2
        )
        // Projektname (case-insensitive)
        XCTAssertEqual(
            AgentSidebarModelBuilder.visibleProjects(manualProjects: [project, other], sessionsByProject: sessionsByProject, query: "rankm8").map(\.name),
            ["RankM8"]
        )
        // Session-Titel
        XCTAssertEqual(
            AgentSidebarModelBuilder.visibleProjects(manualProjects: [project, other], sessionsByProject: sessionsByProject, query: "seo").map(\.name),
            ["Anderes"]
        )
        // Gruppenname
        XCTAssertEqual(
            AgentSidebarModelBuilder.visibleProjects(manualProjects: [project, other], sessionsByProject: sessionsByProject, query: "marketing").map(\.name),
            ["Anderes"]
        )
    }
}

extension AgentSidebarModelBuilderTests {
    private func snapshotFilter(
        _ scope: SidebarScope = .all,
        running: Set<UUID> = [],
        openTabs: Set<UUID> = []
    ) -> SidebarScopeFilter {
        SidebarScopeFilter(
            scope: scope,
            runningSessionIDs: running,
            openTabIDs: openTabs,
            now: Date(timeIntervalSince1970: 1_000_000),
            recentWindow: SidebarScopeFilter.defaultRecentWindow
        )
    }

    func testGroupedSnapshotMatchesExistingBuildersAndSkipsFlatLayout() {
        let project = AgentProject(
            name: "Repo",
            path: "/tmp/repo",
            createdManually: true
        )
        let pinned = makeSidebarSession(projectID: project.id, title: "Pin")
        let newer = makeSidebarSession(
            projectID: project.id,
            title: "Neu",
            lastActivityAt: Date(timeIntervalSince1970: 900_000)
        )
        let older = makeSidebarSession(
            projectID: project.id,
            title: "Alt",
            lastActivityAt: Date(timeIntervalSince1970: 100)
        )
        let workspace = AgentWorkspace(
            projects: [project],
            sessions: [older, pinned, newer]
        )

        let snapshot = AgentSidebarModelBuilder.snapshot(
            workspace: workspace,
            pinnedSessionIDs: [pinned.id],
            scope: snapshotFilter(.all),
            layout: .grouped,
            query: "",
            flatVisibleLimit: 50,
            selectedSessionID: nil
        )
        let expected = AgentSidebarModelBuilder.sessionsByProject(
            workspaceSessions: workspace.sessions,
            pinnedSessionIDs: [pinned.id]
        )

        XCTAssertEqual(snapshot.sessionsByProject, expected)
        XCTAssertEqual(snapshot.visibleProjects, [project])
        XCTAssertEqual(snapshot.visiblePinned, [pinned])
        XCTAssertEqual(snapshot.pinnedOrderIDs, [pinned.id])
        XCTAssertTrue(snapshot.visibleFlatSessions.isEmpty)
        XCTAssertTrue(snapshot.visibleFlatOrderIDs.isEmpty, "Das inaktive Flat-Layout darf nicht materialisiert werden")
        XCTAssertEqual(snapshot.scopeCounts, SidebarScopeCounts(active: 0, recent: 1, all: 2))
        XCTAssertEqual(snapshot.chatCount, 2)
        XCTAssertFalse(snapshot.chatListIsEmpty)
    }

    func testFlatSnapshotSearchesBeforeLimitAndSkipsGroupedLayout() {
        let matchingProject = AgentProject(
            name: "RankM8",
            path: "/tmp/rankm8",
            createdManually: true
        )
        let otherProject = AgentProject(
            name: "Andere",
            path: "/tmp/andere",
            createdManually: true
        )
        let projectMatch = makeSidebarSession(projectID: matchingProject.id, title: "Audit")
        let titleMatch = makeSidebarSession(projectID: otherProject.id, title: "RankM8 Recherche")
        let miss = makeSidebarSession(projectID: otherProject.id, title: "Ohne Treffer")

        let snapshot = AgentSidebarModelBuilder.snapshot(
            workspace: AgentWorkspace(
                projects: [matchingProject, otherProject],
                sessions: [projectMatch, titleMatch, miss]
            ),
            pinnedSessionIDs: [],
            scope: snapshotFilter(.all),
            layout: .flat,
            query: "rankm8",
            flatVisibleLimit: 1,
            selectedSessionID: nil
        )

        XCTAssertEqual(snapshot.chatCount, 2, "Die Suche muss vor dem Flat-Limit greifen")
        XCTAssertEqual(snapshot.visibleFlatSessions.count, 1)
        XCTAssertEqual(snapshot.flatHiddenCount, 1)
        XCTAssertEqual(snapshot.visibleFlatOrderIDs, snapshot.visibleFlatSessions.map(\.id))
        XCTAssertTrue(Set(snapshot.visibleFlatOrderIDs).isSubset(of: [projectMatch.id, titleMatch.id]))
        XCTAssertTrue(snapshot.sessionsByProject.isEmpty)
        XCTAssertTrue(snapshot.visibleProjects.isEmpty, "Das inaktive Grouped-Layout darf nicht materialisiert werden")
    }

    func testFlatSnapshotCapsRowsAndRevealsSelectionWithoutFillingGap() {
        let project = AgentProject(name: "Repo", path: "/tmp/repo", createdManually: true)
        let sessions = (0..<120).map { index in
            makeSidebarSession(
                projectID: project.id,
                title: "S\(index)",
                lastActivityAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        // In der Recency-Sortierung liegt S49 auf Index 70: außerhalb des
        // ersten 50er-Prefix, aber innerhalb des nächsten 100er-Prefix.
        let selected = sessions[49]

        let snapshot = AgentSidebarModelBuilder.snapshot(
            workspace: AgentWorkspace(projects: [project], sessions: sessions),
            pinnedSessionIDs: [],
            scope: snapshotFilter(.all),
            layout: .flat,
            query: "",
            flatVisibleLimit: 50,
            selectedSessionID: selected.id
        )
        let expanded = AgentSidebarModelBuilder.snapshot(
            workspace: AgentWorkspace(projects: [project], sessions: sessions),
            pinnedSessionIDs: [],
            scope: snapshotFilter(.all),
            layout: .flat,
            query: "",
            flatVisibleLimit: 100,
            selectedSessionID: selected.id
        )

        XCTAssertEqual(snapshot.visibleFlatOrderIDs, snapshot.visibleFlatSessions.map(\.id))
        XCTAssertEqual(snapshot.visibleFlatSessions.count, 50)
        XCTAssertTrue(snapshot.visibleFlatSessions.contains { $0.id == selected.id })
        XCTAssertEqual(snapshot.flatHiddenCount, 70)
        XCTAssertEqual(
            Set(expanded.visibleFlatOrderIDs).subtracting(snapshot.visibleFlatOrderIDs).count,
            50,
            "Der +50-Schritt muss trotz Reveal genau 50 neue sichtbare Rows liefern"
        )
    }

    func testFlatSnapshotRevealsParentOfSelectedSubagentChild() {
        let project = AgentProject(name: "Repo", path: "/tmp/repo", createdManually: true)
        var parent = makeSidebarSession(
            projectID: project.id,
            title: "Parent",
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        parent.externalSessionID = "parent-external"
        let child = AgentChatSession(
            provider: .codex,
            projectID: project.id,
            title: "Child",
            createdAt: Date(timeIntervalSince1970: 0),
            lastActivityAt: Date(timeIntervalSince1970: 200),
            createdManually: true,
            kind: .subagentJob,
            subagentParentSessionID: "parent-external"
        )
        let newerRoots = (1...60).map { index in
            makeSidebarSession(
                projectID: project.id,
                title: "Root \(index)",
                lastActivityAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let snapshot = AgentSidebarModelBuilder.snapshot(
            workspace: AgentWorkspace(
                projects: [project],
                sessions: newerRoots + [parent, child]
            ),
            pinnedSessionIDs: [],
            scope: snapshotFilter(.all),
            layout: .flat,
            query: "",
            flatVisibleLimit: 50,
            selectedSessionID: child.id
        )

        XCTAssertTrue(snapshot.visibleFlatSessions.contains { $0.id == parent.id })
        XCTAssertFalse(snapshot.visibleFlatSessions.contains { $0.id == child.id })
        XCTAssertEqual(snapshot.subagentChildrenByParent[parent.id], [child])
    }

    func testOpenSubagentMakesItsOldParentVisibleInActiveScope() {
        let project = AgentProject(name: "Repo", path: "/tmp/repo", createdManually: true)
        var parent = makeSidebarSession(
            projectID: project.id,
            title: "Alter Parent",
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        parent.externalSessionID = "active-parent"
        let child = AgentChatSession(
            provider: .codex,
            projectID: project.id,
            title: "Offenes Child",
            createdAt: Date(timeIntervalSince1970: 0),
            lastActivityAt: Date(timeIntervalSince1970: 0),
            createdManually: true,
            kind: .subagentJob,
            subagentParentSessionID: "active-parent"
        )
        let workspace = AgentWorkspace(projects: [project], sessions: [parent, child])
        let activeScope = snapshotFilter(.active, openTabs: [child.id])

        let flat = AgentSidebarModelBuilder.snapshot(
            workspace: workspace,
            pinnedSessionIDs: [],
            scope: activeScope,
            layout: .flat,
            query: "",
            flatVisibleLimit: 50,
            selectedSessionID: child.id
        )
        let grouped = AgentSidebarModelBuilder.snapshot(
            workspace: workspace,
            pinnedSessionIDs: [],
            scope: activeScope,
            layout: .grouped,
            query: "",
            flatVisibleLimit: 50,
            selectedSessionID: child.id
        )

        XCTAssertEqual(flat.visibleFlatSessions.map(\.id), [parent.id])
        XCTAssertEqual(flat.scopeCounts.active, 1)
        XCTAssertEqual(grouped.visibleProjects, [project])
        XCTAssertEqual(grouped.sessionsByProject[project.id]?.map(\.id), [parent.id])
        XCTAssertEqual(grouped.scopeCounts.active, 1)
    }

    func testGroupedSnapshotKeepsEmptyManualProjectVisibleInAllScope() {
        let project = AgentProject(name: "Leer", path: "/tmp/leer", createdManually: true)
        let snapshot = AgentSidebarModelBuilder.snapshot(
            workspace: AgentWorkspace(projects: [project], sessions: []),
            pinnedSessionIDs: [],
            scope: snapshotFilter(.all),
            layout: .grouped,
            query: "",
            flatVisibleLimit: 50,
            selectedSessionID: nil
        )

        XCTAssertEqual(snapshot.visibleProjects, [project])
        XCTAssertEqual(snapshot.chatCount, 0)
        XCTAssertFalse(snapshot.chatListIsEmpty)
    }

    func testFlatSnapshotClassifiesTenThousandSessionsWithoutMaterializingAllRows() {
        let project = AgentProject(name: "Groß", path: "/tmp/gross", createdManually: true)
        let sessions = (0..<10_000).map { index in
            makeSidebarSession(
                projectID: project.id,
                title: "Session \(index)",
                lastActivityAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let pinnedIDs = Array(sessions.prefix(100).map(\.id))

        let snapshot = AgentSidebarModelBuilder.snapshot(
            workspace: AgentWorkspace(projects: [project], sessions: sessions),
            pinnedSessionIDs: pinnedIDs,
            scope: snapshotFilter(.all),
            layout: .flat,
            query: "",
            flatVisibleLimit: 50,
            selectedSessionID: nil
        )

        XCTAssertEqual(snapshot.scopeCounts.all, 9_900)
        XCTAssertEqual(snapshot.chatCount, 9_900)
        XCTAssertEqual(snapshot.visibleFlatOrderIDs.count, 50)
        XCTAssertEqual(snapshot.visibleFlatOrderIDs, snapshot.visibleFlatSessions.map(\.id))
        XCTAssertEqual(snapshot.flatHiddenCount, 9_850)
        XCTAssertEqual(snapshot.visiblePinned.count, 100)
        XCTAssertEqual(snapshot.eligibleRootRowCount, 150)
        XCTAssertTrue(snapshot.sessionsByProject.isEmpty)
    }
}

// MARK: - Sichtbarkeits-Slice (P4 S5)

final class SidebarVisibleSliceTests: XCTestCase {
    private func makeSessions(_ count: Int) -> [AgentChatSession] {
        let projectID = UUID()
        return (0..<count).map { makeSidebarSession(projectID: projectID, title: "S\($0)") }
    }

    func testSliceCapsAndCountsHidden() {
        let result = ProjectChatGroup.visibleSlice(of: makeSessions(25), limit: 20)
        XCTAssertEqual(result.visible.count, 20)
        XCTAssertEqual(result.hiddenCount, 5)
    }

    func testSliceWithFewerSessionsThanLimit() {
        let result = ProjectChatGroup.visibleSlice(of: makeSessions(10), limit: 20)
        XCTAssertEqual(result.visible.count, 10)
        XCTAssertEqual(result.hiddenCount, 0)
    }

    func testSliceExactlyAtLimit() {
        let result = ProjectChatGroup.visibleSlice(of: makeSessions(20), limit: 20)
        XCTAssertEqual(result.visible.count, 20)
        XCTAssertEqual(result.hiddenCount, 0)
    }

    /// Selektions-Reveal: liegt die Muss-Row jenseits des Limits, wird bis zu
    /// ihr aufgefüllt (sonst bliebe z.B. der Parent eines per Notification
    /// selektierten Subagent-Kindes unsichtbar).
    func testSliceExtendsToIncludeSelectionBeyondLimit() {
        let sessions = makeSessions(30)
        let target = sessions[24]
        let result = ProjectChatGroup.visibleSlice(of: sessions, limit: 20, mustIncludeID: target.id)
        XCTAssertEqual(result.visible.count, 25)
        XCTAssertTrue(result.visible.contains { $0.id == target.id })
        XCTAssertEqual(result.hiddenCount, 5)
    }

    func testSliceUnchangedWhenSelectionWithinLimit() {
        let sessions = makeSessions(30)
        let result = ProjectChatGroup.visibleSlice(of: sessions, limit: 20, mustIncludeID: sessions[3].id)
        XCTAssertEqual(result.visible.count, 20)
        XCTAssertEqual(result.hiddenCount, 10)
    }

    func testSliceIgnoresUnknownMustIncludeID() {
        let result = ProjectChatGroup.visibleSlice(of: makeSessions(25), limit: 20, mustIncludeID: UUID())
        XCTAssertEqual(result.visible.count, 20)
        XCTAssertEqual(result.hiddenCount, 5)
    }
}

// MARK: - Scope-Filter (Aktiv·Zuletzt·Alle) + Flach-Layout

final class SidebarScopeFilterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let projectID = UUID()

    private func filter(_ scope: SidebarScope, running: Set<UUID> = [], openTabs: Set<UUID> = []) -> SidebarScopeFilter {
        SidebarScopeFilter(
            scope: scope,
            runningSessionIDs: running,
            openTabIDs: openTabs,
            now: now,
            recentWindow: 7 * 24 * 3600
        )
    }

    func testActiveScopeShowsRunningOpenTabsOnly() {
        let running = makeSidebarSession(projectID: projectID, title: "Läuft")
        let openTab = makeSidebarSession(projectID: projectID, title: "Offen")
        let old = makeSidebarSession(projectID: projectID, title: "Alt", lastActivityAt: now.addingTimeInterval(-30 * 24 * 3600))

        let f = filter(.active, running: [running.id], openTabs: [openTab.id])
        XCTAssertTrue(f.matches(running))
        XCTAssertTrue(f.matches(openTab))
        XCTAssertFalse(f.matches(old), "Alte, weder laufende noch offene Chats fallen in Aktiv raus")
    }

    func testRecentScopeAddsRecentlyActive() {
        let recent = makeSidebarSession(projectID: projectID, title: "Neulich", lastActivityAt: now.addingTimeInterval(-2 * 24 * 3600))
        let old = makeSidebarSession(projectID: projectID, title: "Alt", lastActivityAt: now.addingTimeInterval(-30 * 24 * 3600))

        let f = filter(.recent)
        XCTAssertTrue(f.matches(recent), "Innerhalb des 7-Tage-Fensters → in Zuletzt")
        XCTAssertFalse(f.matches(old), "Außerhalb des Fensters → nicht in Zuletzt")
    }

    func testRunningAlwaysVisibleEvenWhenOld() {
        let oldButRunning = makeSidebarSession(projectID: projectID, title: "Alt aber läuft", lastActivityAt: now.addingTimeInterval(-90 * 24 * 3600))
        XCTAssertTrue(filter(.active, running: [oldButRunning.id]).matches(oldButRunning))
        XCTAssertTrue(filter(.recent, running: [oldButRunning.id]).matches(oldButRunning))
        XCTAssertTrue(filter(.all).matches(oldButRunning))
    }

    func testAllScopeShowsEverything() {
        let old = makeSidebarSession(projectID: projectID, title: "Uralt", lastActivityAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(filter(.all).matches(old))
    }

    func testFlatSessionsAreRecencySortedAndScopeFiltered() {
        let a = makeSidebarSession(projectID: projectID, title: "A", lastActivityAt: now.addingTimeInterval(-1 * 24 * 3600))
        let b = makeSidebarSession(projectID: UUID(), title: "B", lastActivityAt: now)
        let old = makeSidebarSession(projectID: projectID, title: "Alt", lastActivityAt: now.addingTimeInterval(-30 * 24 * 3600))

        let flat = AgentSidebarModelBuilder.flatSessions(
            workspaceSessions: [a, b, old],
            pinnedSessionIDs: [],
            scope: filter(.recent)
        )
        XCTAssertEqual(flat.map(\.title), ["B", "A"], "Recency-Sort absteigend, Alt raus (außerhalb Fenster)")
    }

    func testScopeCountsMatchFilters() {
        let running = makeSidebarSession(projectID: projectID, title: "Läuft", lastActivityAt: now.addingTimeInterval(-90 * 24 * 3600))
        let recent = makeSidebarSession(projectID: projectID, title: "Neulich", lastActivityAt: now.addingTimeInterval(-2 * 24 * 3600))
        let old = makeSidebarSession(projectID: projectID, title: "Alt", lastActivityAt: now.addingTimeInterval(-30 * 24 * 3600))

        let counts = AgentSidebarModelBuilder.scopeCounts(
            workspaceSessions: [running, recent, old],
            pinnedSessionIDs: [],
            runningSessionIDs: [running.id],
            openTabIDs: [],
            now: now,
            recentWindow: 7 * 24 * 3600
        )
        XCTAssertEqual(counts.active, 1, "nur die laufende")
        XCTAssertEqual(counts.recent, 2, "laufende + kürzlich aktive")
        XCTAssertEqual(counts.all, 3, "alle nicht-archivierten manuellen")
    }
}

// MARK: - Subagent-Kinder (Slice 3)

final class AgentSidebarSubagentChildrenTests: XCTestCase {
    private let projectID = UUID()

    private func makeSubagentSession(
        title: String = "Subagent",
        parentExternalID: String?,
        status: AgentChatStatus = .closed
    ) -> AgentChatSession {
        var session = AgentChatSession(
            provider: .codex,
            projectID: projectID,
            externalSessionID: "thread-\(UUID().uuidString)",
            title: title,
            createdAt: Date(timeIntervalSince1970: 500),
            lastActivityAt: Date(timeIntervalSince1970: 1_000),
            createdManually: true,
            kind: .subagentJob,
            subagentJobShortID: "a1b2c3d4",
            subagentParentSessionID: parentExternalID
        )
        session.status = status
        return session
    }

    private func makeParent(externalID: String?) -> AgentChatSession {
        var session = makeSidebarSession(projectID: projectID, title: "Parent")
        session.externalSessionID = externalID
        return session
    }

    func testSubagentChildrenGroupsByParent() {
        let parent = makeParent(externalID: "claude-ext-1")
        let childA = makeSubagentSession(title: "Kind A", parentExternalID: "claude-ext-1")
        let childB = makeSubagentSession(title: "Kind B", parentExternalID: "claude-ext-1")

        let result = AgentSidebarModelBuilder.subagentChildren(
            workspaceSessions: [parent, childA, childB]
        )
        XCTAssertEqual(result.byParentLocalID[parent.id]?.count, 2)
        XCTAssertTrue(result.orphans.isEmpty)
    }

    func testOrphanFallbackWhenParentMissingOrHidden() {
        let archivedParent = {
            var session = makeSidebarSession(projectID: projectID, title: "Archiv", status: .archived)
            session.externalSessionID = "claude-archiviert"
            return session
        }()
        let noParent = makeSubagentSession(title: "Ohne Parent", parentExternalID: nil)
        let unknownParent = makeSubagentSession(title: "Parent unbekannt", parentExternalID: "gibts-nicht")
        let hiddenParentChild = makeSubagentSession(title: "Parent archiviert", parentExternalID: "claude-archiviert")

        let result = AgentSidebarModelBuilder.subagentChildren(
            workspaceSessions: [archivedParent, noParent, unknownParent, hiddenParentChild]
        )
        XCTAssertTrue(result.byParentLocalID.isEmpty)
        XCTAssertEqual(
            Set(result.orphans.map(\.title)),
            ["Ohne Parent", "Parent unbekannt", "Parent archiviert"],
            "Kinder ohne sichtbaren Parent fallen als normale Rows zurück"
        )
    }

    func testArchivedChildrenAreExcluded() {
        let parent = makeParent(externalID: "claude-ext-1")
        let archived = makeSubagentSession(title: "Weg", parentExternalID: "claude-ext-1", status: .archived)

        let result = AgentSidebarModelBuilder.subagentChildren(
            workspaceSessions: [parent, archived]
        )
        XCTAssertNil(result.byParentLocalID[parent.id])
        XCTAssertTrue(result.orphans.isEmpty)
    }

    func testMainListsExcludeChildrenButKeepOrphans() {
        let parent = makeParent(externalID: "claude-ext-1")
        let child = makeSubagentSession(title: "Kind", parentExternalID: "claude-ext-1")
        let orphan = makeSubagentSession(title: "Orphan", parentExternalID: nil)

        let children = AgentSidebarModelBuilder.subagentChildren(
            workspaceSessions: [parent, child, orphan]
        )
        let childIDs = Set(children.byParentLocalID.values.flatMap { $0 }.map(\.id))

        let grouped = AgentSidebarModelBuilder.sessionsByProject(
            workspaceSessions: [parent, child, orphan],
            pinnedSessionIDs: [],
            subagentChildIDs: childIDs
        )
        XCTAssertEqual(
            Set((grouped[projectID] ?? []).map(\.title)),
            ["Parent", "Orphan"],
            "Kinder raus aus der Hauptliste, Orphans bleiben als normale Rows"
        )

        let flat = AgentSidebarModelBuilder.flatSessions(
            workspaceSessions: [parent, child, orphan],
            pinnedSessionIDs: [],
            subagentChildIDs: childIDs
        )
        XCTAssertEqual(Set(flat.map(\.title)), ["Parent", "Orphan"])

        let counts = AgentSidebarModelBuilder.scopeCounts(
            workspaceSessions: [parent, child, orphan],
            pinnedSessionIDs: [],
            runningSessionIDs: [],
            openTabIDs: [],
            now: Date(timeIntervalSince1970: 1_000),
            subagentChildIDs: childIDs
        )
        XCTAssertEqual(counts.all, 2, "Kinder zählen nicht in die Scope-Zähler")
    }
}

// MARK: - „Zuletzt aktiv"-Formatierung (Sidebar-Zeilen)

final class SidebarRelativeTimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func label(secondsAgo: TimeInterval) -> String {
        SidebarRelativeTime.short(now.addingTimeInterval(-secondsAgo), now: now)
    }

    func testFormatsAcrossUnits() {
        XCTAssertEqual(label(secondsAgo: 5), "jetzt")
        XCTAssertEqual(label(secondsAgo: 59), "jetzt")
        XCTAssertEqual(label(secondsAgo: 60), "1m")
        XCTAssertEqual(label(secondsAgo: 45 * 60), "45m")
        XCTAssertEqual(label(secondsAgo: 60 * 60), "1h")
        XCTAssertEqual(label(secondsAgo: 5 * 3600), "5h")
        XCTAssertEqual(label(secondsAgo: 24 * 3600), "1d")
        XCTAssertEqual(label(secondsAgo: 3 * 24 * 3600), "3d")
        XCTAssertEqual(label(secondsAgo: 7 * 24 * 3600), "1w")
        XCTAssertEqual(label(secondsAgo: 21 * 24 * 3600), "3w")
        XCTAssertEqual(label(secondsAgo: 60 * 24 * 3600), "2mo")
    }
}

// MARK: - Subagent-Split für Variante D (Aktive sichtbar, Fertige in den Fuß)

final class AgentSidebarSubagentSplitTests: XCTestCase {
    private let projectID = UUID()

    /// Kind mit kontrollierbarer ID und Recency — für Rang- und Tiebreak-Tests.
    private func child(
        id: UUID = UUID(),
        title: String = "Kind",
        secondsSinceEpoch: TimeInterval = 1_000
    ) -> AgentChatSession {
        var session = AgentChatSession(
            id: id,
            provider: .codex,
            projectID: projectID,
            externalSessionID: "thread-\(UUID().uuidString)",
            title: title,
            createdAt: Date(timeIntervalSince1970: 500),
            lastActivityAt: Date(timeIntervalSince1970: secondsSinceEpoch),
            createdManually: true,
            kind: .subagentJob,
            subagentJobShortID: "a1b2c3d4",
            subagentParentSessionID: "parent-ext"
        )
        session.status = .closed
        return session
    }

    func testErroredRankBeforeWorkingInVisible() {
        let working = child(title: "läuft")
        let errored = child(title: "kaputt")
        let split = AgentSidebarModelBuilder.subagentChildSplit(
            children: [working, errored],
            erroredIDs: [errored.id],
            workingIDs: [working.id],
            unreadIDs: [],
            selectedID: nil
        )
        XCTAssertEqual(split.visible.map(\.title), ["kaputt", "läuft"])
        XCTAssertTrue(split.hidden.isEmpty)
    }

    func testUnreadDoneChildIsHiddenNotVisible() {
        let unread = child(title: "fertig-ungelesen")
        let split = AgentSidebarModelBuilder.subagentChildSplit(
            children: [unread],
            erroredIDs: [],
            workingIDs: [],
            unreadIDs: [unread.id],
            selectedID: nil
        )
        XCTAssertTrue(split.visible.isEmpty, "Fertig = Fuß, auch wenn ungelesen")
        XCTAssertEqual(split.hidden.map(\.title), ["fertig-ungelesen"])
        XCTAssertEqual(split.hiddenUnreadCount, 1)
    }

    func testHiddenOrdersUnreadBeforeSeen() {
        // Gesichtetes ist NEUER, würde bei reiner Recency vorn stehen —
        // der Split muss Ungelesenes trotzdem zuerst listen.
        let seen = child(title: "gesichtet", secondsSinceEpoch: 9_000)
        let unread = child(title: "ungelesen", secondsSinceEpoch: 1_000)
        let split = AgentSidebarModelBuilder.subagentChildSplit(
            children: [seen, unread],
            erroredIDs: [],
            workingIDs: [],
            unreadIDs: [unread.id],
            selectedID: nil
        )
        XCTAssertEqual(split.hidden.map(\.title), ["ungelesen", "gesichtet"])
    }

    func testAllWorkingChildrenVisibleWithoutCap() {
        let kids = (0..<12).map { child(title: "w\($0)") }
        let split = AgentSidebarModelBuilder.subagentChildSplit(
            children: kids,
            erroredIDs: [],
            workingIDs: Set(kids.map(\.id)),
            unreadIDs: [],
            selectedID: nil
        )
        XCTAssertEqual(split.visible.count, 12)
        XCTAssertTrue(split.hidden.isEmpty)
        XCTAssertEqual(split.workingCount, 12)
    }

    func testAllErroredChildrenVisibleWithoutCap() {
        let kids = (0..<20).map { child(title: "e\($0)") }
        let split = AgentSidebarModelBuilder.subagentChildSplit(
            children: kids,
            erroredIDs: Set(kids.map(\.id)),
            workingIDs: [],
            unreadIDs: [],
            selectedID: nil
        )
        XCTAssertEqual(split.visible.count, 20)
        XCTAssertEqual(split.erroredCount, 20)
    }

    func testSelectedSeenChildIsRevealedInVisible() {
        let seen = child(title: "gesichtet-selektiert")
        let split = AgentSidebarModelBuilder.subagentChildSplit(
            children: [seen],
            erroredIDs: [],
            workingIDs: [],
            unreadIDs: [],
            selectedID: seen.id
        )
        XCTAssertEqual(split.visible.map(\.title), ["gesichtet-selektiert"])
        XCTAssertTrue(split.hidden.isEmpty)
    }

    func testSelectedUnreadChildRevealedAndNotDoubleCounted() {
        let unread = child(title: "ungelesen-selektiert")
        let split = AgentSidebarModelBuilder.subagentChildSplit(
            children: [unread],
            erroredIDs: [],
            workingIDs: [],
            unreadIDs: [unread.id],
            selectedID: unread.id
        )
        XCTAssertEqual(split.visible.map(\.title), ["ungelesen-selektiert"])
        XCTAssertTrue(split.hidden.isEmpty, "Selektiert schlägt Fuß — keine Dopplung")
        XCTAssertEqual(split.hiddenUnreadCount, 0)
    }

    func testAllDoneCollapsesVisibleAndFillsFooter() {
        let kids = (0..<15).map { child(title: "d\($0)") }
        let split = AgentSidebarModelBuilder.subagentChildSplit(
            children: kids,
            erroredIDs: [],
            workingIDs: [],
            unreadIDs: [],
            selectedID: nil
        )
        XCTAssertTrue(split.visible.isEmpty)
        XCTAssertEqual(split.hidden.count, 15)
    }

    func testEmptyChildrenYieldEmptySplit() {
        let split = AgentSidebarModelBuilder.subagentChildSplit(
            children: [],
            erroredIDs: [],
            workingIDs: [],
            unreadIDs: [],
            selectedID: nil
        )
        XCTAssertTrue(split.visible.isEmpty)
        XCTAssertTrue(split.hidden.isEmpty)
        XCTAssertEqual(split.totalCount, 0)
    }

    func testTerminalCountIsTotalMinusWorking() {
        // 6 Kinder: 2 laufen, 1 kaputt, 3 fertig → terminal = 4, Nenner = 6.
        let working = (0..<2).map { child(title: "w\($0)") }
        let errored = child(title: "e")
        let done = (0..<3).map { child(title: "d\($0)") }
        let split = AgentSidebarModelBuilder.subagentChildSplit(
            children: working + [errored] + done,
            erroredIDs: [errored.id],
            workingIDs: Set(working.map(\.id)),
            unreadIDs: [],
            selectedID: nil
        )
        XCTAssertEqual(split.workingCount, 2)
        XCTAssertEqual(split.totalCount, 6)
        XCTAssertEqual(split.terminalCount, 4)
    }

    func testDeterministicTiebreakOnEqualRecency() {
        // Zwei laufende Kinder mit identischem lastActivityAt: die Reihenfolge
        // muss stabil nach ID-UUID sein, nicht implementierungsabhängig.
        let idLow = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let idHigh = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000000")!
        let a = child(id: idHigh, title: "high", secondsSinceEpoch: 5_000)
        let b = child(id: idLow, title: "low", secondsSinceEpoch: 5_000)
        let split = AgentSidebarModelBuilder.subagentChildSplit(
            children: [a, b],
            erroredIDs: [],
            workingIDs: [a.id, b.id],
            unreadIDs: [],
            selectedID: nil
        )
        XCTAssertEqual(split.visible.map(\.title), ["low", "high"])
    }
}
