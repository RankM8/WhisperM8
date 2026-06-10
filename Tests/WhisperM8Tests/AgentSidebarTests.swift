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
        isRunning: Bool = false,
        isAwaitingInput: Bool = false,
        isAutoRenaming: Bool = false,
        store: AgentSessionRuntimeStatusStore? = nil
    ) -> SessionListButton {
        SessionListButton(
            session: session,
            isSelected: isSelected,
            isRunning: isRunning,
            statusStore: store ?? AgentSessionRuntimeStatusStore(),
            isAwaitingInput: isAwaitingInput,
            isAutoRenaming: isAutoRenaming,
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
        XCTAssertNotEqual(base, makeButton(session: session, isRunning: true))
        XCTAssertNotEqual(base, makeButton(session: session, isAwaitingInput: true))
        XCTAssertNotEqual(base, makeButton(session: session, isAutoRenaming: true))
    }
}

// MARK: - Sidebar-Modell-Builder (P4 S4)

final class AgentSidebarModelBuilderTests: XCTestCase {
    func testGroupingFiltersArchivedNonManualAndClosedTabs() {
        let projectID = UUID()
        let open = makeSidebarSession(projectID: projectID, title: "Offen")
        let archived = makeSidebarSession(projectID: projectID, title: "Archiv", status: .archived)
        let notManual = makeSidebarSession(projectID: projectID, title: "Import", createdManually: nil)
        let closedTab = makeSidebarSession(projectID: projectID, title: "Zu")
        let selectedButClosed = makeSidebarSession(projectID: projectID, title: "Selektiert")

        let grouped = AgentSidebarModelBuilder.sessionsByProject(
            workspaceSessions: [open, archived, notManual, closedTab, selectedButClosed],
            openTabIDs: [open.id, archived.id, notManual.id],
            selectedSessionID: selectedButClosed.id
        )

        let titles = (grouped[projectID] ?? []).map(\.title)
        XCTAssertTrue(titles.contains("Offen"))
        XCTAssertTrue(titles.contains("Selektiert"), "Selektierte Session ist auch ohne offenen Tab sichtbar")
        XCTAssertFalse(titles.contains("Archiv"))
        XCTAssertFalse(titles.contains("Import"))
        XCTAssertFalse(titles.contains("Zu"))
    }

    func testGroupingSortsLikeAgentSessionStore() {
        let projectID = UUID()
        let older = makeSidebarSession(projectID: projectID, title: "Alt", lastActivityAt: Date(timeIntervalSince1970: 100))
        let newer = makeSidebarSession(projectID: projectID, title: "Neu", lastActivityAt: Date(timeIntervalSince1970: 200))

        let grouped = AgentSidebarModelBuilder.sessionsByProject(
            workspaceSessions: [older, newer],
            openTabIDs: [older.id, newer.id],
            selectedSessionID: nil
        )

        XCTAssertEqual(
            (grouped[projectID] ?? []).map(\.title),
            AgentSessionStore.sortedSessions([older, newer]).map(\.title),
            "Sortierung muss identisch zu AgentSessionStore.sortedSessions sein"
        )
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
