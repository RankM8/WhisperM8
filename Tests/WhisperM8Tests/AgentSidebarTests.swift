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
        isRunning: Bool = false,
        isAwaitingInput: Bool = false,
        isAutoRenaming: Bool = false,
        isMissingTranscript: Bool = false,
        store: AgentSessionRuntimeStatusStore? = nil
    ) -> SessionListButton {
        SessionListButton(
            session: session,
            isSelected: isSelected,
            isOpenTab: isOpenTab,
            accentColorHex: accentColorHex,
            isRunning: isRunning,
            statusStore: store ?? AgentSessionRuntimeStatusStore(),
            isAwaitingInput: isAwaitingInput,
            isAutoRenaming: isAutoRenaming,
            isMissingTranscript: isMissingTranscript,
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
        XCTAssertNotEqual(base, makeButton(session: session, isRunning: true))
        XCTAssertNotEqual(base, makeButton(session: session, isAwaitingInput: true))
        XCTAssertNotEqual(base, makeButton(session: session, isAutoRenaming: true))
        XCTAssertNotEqual(base, makeButton(session: session, isMissingTranscript: true))
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
