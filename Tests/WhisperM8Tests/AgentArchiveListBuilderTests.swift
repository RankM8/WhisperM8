import Foundation
import XCTest
@testable import WhisperM8

/// Tests für die pure Gruppierungs-/Sortier-/Suchlogik des Archiv-Modus.
final class AgentArchiveListBuilderTests: XCTestCase {
    private func makeArchivedSession(
        projectID: UUID,
        title: String,
        archivedAt: Date?,
        lastActivityAt: Date = Date(timeIntervalSince1970: 0)
    ) -> AgentChatSession {
        AgentChatSession(
            provider: .claude,
            projectID: projectID,
            title: title,
            status: .archived,
            createdAt: Date(timeIntervalSince1970: 0),
            lastActivityAt: lastActivityAt,
            archivedAt: archivedAt,
            createdManually: true
        )
    }

    func testBuilderSortsByArchivedAtDescendingWithLastActivityFallback() {
        let project = AgentProject(name: "Repo", path: "/tmp/repo")
        let old = makeArchivedSession(
            projectID: project.id,
            title: "Alt",
            archivedAt: Date(timeIntervalSince1970: 100)
        )
        let new = makeArchivedSession(
            projectID: project.id,
            title: "Neu",
            archivedAt: Date(timeIntervalSince1970: 300)
        )
        // Legacy-Archivierte ohne archivedAt fallen auf lastActivityAt zurück.
        let legacy = makeArchivedSession(
            projectID: project.id,
            title: "Legacy",
            archivedAt: nil,
            lastActivityAt: Date(timeIntervalSince1970: 200)
        )

        let groups = AgentArchiveListBuilder.build(
            sessions: [old, legacy, new],
            projects: [project],
            query: ""
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.sessions.map(\.title), ["Neu", "Legacy", "Alt"])
    }

    func testBuilderGroupsByProjectNewestGroupFirst() {
        let stale = AgentProject(name: "Altes Repo", path: "/tmp/alt")
        let fresh = AgentProject(name: "Frisches Repo", path: "/tmp/frisch")
        let staleSession = makeArchivedSession(
            projectID: stale.id,
            title: "Alter Chat",
            archivedAt: Date(timeIntervalSince1970: 100)
        )
        let freshSession = makeArchivedSession(
            projectID: fresh.id,
            title: "Frischer Chat",
            archivedAt: Date(timeIntervalSince1970: 900)
        )

        let groups = AgentArchiveListBuilder.build(
            sessions: [staleSession, freshSession],
            projects: [stale, fresh],
            query: ""
        )

        XCTAssertEqual(groups.map { $0.project?.name }, ["Frisches Repo", "Altes Repo"])
    }

    func testBuilderSearchMatchesTitleAndProjectNameCaseInsensitive() {
        let project = AgentProject(name: "WhisperM8", path: "/tmp/whisperm8")
        let other = AgentProject(name: "ListM8", path: "/tmp/listm8")
        let byTitle = makeArchivedSession(
            projectID: other.id,
            title: "Overlay-Redesign",
            archivedAt: Date(timeIntervalSince1970: 100)
        )
        let byProject = makeArchivedSession(
            projectID: project.id,
            title: "Irgendein Chat",
            archivedAt: Date(timeIntervalSince1970: 200)
        )

        let titleHits = AgentArchiveListBuilder.build(
            sessions: [byTitle, byProject],
            projects: [project, other],
            query: "overlay"
        )
        XCTAssertEqual(titleHits.flatMap(\.sessions).map(\.title), ["Overlay-Redesign"])

        let projectHits = AgentArchiveListBuilder.build(
            sessions: [byTitle, byProject],
            projects: [project, other],
            query: "whisper"
        )
        XCTAssertEqual(projectHits.flatMap(\.sessions).map(\.title), ["Irgendein Chat"])
    }

    func testBuilderPutsSessionsOfDeletedProjectsInFallbackGroup() {
        let project = AgentProject(name: "Repo", path: "/tmp/repo")
        let owned = makeArchivedSession(
            projectID: project.id,
            title: "Mit Projekt",
            archivedAt: Date(timeIntervalSince1970: 100)
        )
        // Verwaiste projectID (Projekt gelöscht / Legacy-Daten): jüngerer
        // Zeitstempel, trotzdem gehört die Sammelgruppe ans Ende.
        let orphan = makeArchivedSession(
            projectID: UUID(),
            title: "Verwaist",
            archivedAt: Date(timeIntervalSince1970: 900)
        )

        let groups = AgentArchiveListBuilder.build(
            sessions: [owned, orphan],
            projects: [project],
            query: ""
        )

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first?.project?.name, "Repo")
        XCTAssertNil(groups.last?.project)
        XCTAssertEqual(groups.last?.sessions.map(\.title), ["Verwaist"])
    }
}
