import Foundation
import XCTest
@testable import WhisperM8

final class ClaudeActiveSessionResolverTests: XCTestCase {
    // MARK: - ClaudeActiveSessionResolver

    private func makeIndexedClaudeSession(
        id: String,
        cwd: String,
        lastActivityAt: Date,
        title: String = "Some Session"
    ) -> IndexedAgentSession {
        IndexedAgentSession(
            provider: .claude,
            externalSessionID: id,
            cwd: cwd,
            title: title,
            model: nil,
            reasoningEffort: nil,
            createdAt: lastActivityAt.addingTimeInterval(-3600),
            lastActivityAt: lastActivityAt
        )
    }

    func testClaudeActiveSessionResolverReturnsUnchangedWhenNoNewActivity() {
        let entry = ClaudeActiveSessionTrackerEntry(
            localSessionID: UUID(),
            projectCwd: "/tmp/repo",
            currentExternalID: "current",
            launchedAt: Date()
        )
        let indexed = [
            makeIndexedClaudeSession(id: "current", cwd: "/tmp/repo", lastActivityAt: Date()),
            // Andere Session liegt VOR Launch → kein Kandidat.
            makeIndexedClaudeSession(id: "older", cwd: "/tmp/repo", lastActivityAt: Date().addingTimeInterval(-600))
        ]
        let decision = ClaudeActiveSessionResolver.decide(entry: entry, indexedSessions: indexed)
        XCTAssertEqual(decision, .unchanged)
    }

    func testClaudeActiveSessionResolverRebindsOnSingleNewCandidate() {
        let launched = Date().addingTimeInterval(-30)
        let entry = ClaudeActiveSessionTrackerEntry(
            localSessionID: UUID(),
            projectCwd: "/tmp/repo",
            currentExternalID: "current",
            launchedAt: launched
        )
        let indexed = [
            makeIndexedClaudeSession(id: "current", cwd: "/tmp/repo", lastActivityAt: launched),
            makeIndexedClaudeSession(id: "new-one", cwd: "/tmp/repo", lastActivityAt: Date(), title: "Fresh Chat")
        ]
        let decision = ClaudeActiveSessionResolver.decide(entry: entry, indexedSessions: indexed)
        XCTAssertEqual(decision, .rebind(newExternalID: "new-one", title: "Fresh Chat"))
    }

    func testClaudeActiveSessionResolverIgnoresOtherProjects() {
        let launched = Date().addingTimeInterval(-30)
        let entry = ClaudeActiveSessionTrackerEntry(
            localSessionID: UUID(),
            projectCwd: "/tmp/repo",
            currentExternalID: "current",
            launchedAt: launched
        )
        let indexed = [
            makeIndexedClaudeSession(id: "current", cwd: "/tmp/repo", lastActivityAt: launched),
            // Andere CWD darf NIE als Kandidat zaehlen, selbst wenn frischer.
            makeIndexedClaudeSession(id: "wrong-repo", cwd: "/tmp/different", lastActivityAt: Date())
        ]
        let decision = ClaudeActiveSessionResolver.decide(entry: entry, indexedSessions: indexed)
        XCTAssertEqual(decision, .unchanged)
    }

    func testClaudeActiveSessionResolverReturnsAmbiguousOnCompetingCandidates() {
        let launched = Date().addingTimeInterval(-30)
        let entry = ClaudeActiveSessionTrackerEntry(
            localSessionID: UUID(),
            projectCwd: "/tmp/repo",
            currentExternalID: "current",
            launchedAt: launched
        )
        let now = Date()
        let indexed = [
            makeIndexedClaudeSession(id: "candidate-a", cwd: "/tmp/repo", lastActivityAt: now),
            // < 2s Differenz → ambiguous.
            makeIndexedClaudeSession(id: "candidate-b", cwd: "/tmp/repo", lastActivityAt: now.addingTimeInterval(-1))
        ]
        let decision = ClaudeActiveSessionResolver.decide(entry: entry, indexedSessions: indexed)
        if case .ambiguous(let candidates) = decision {
            XCTAssertEqual(candidates.count, 2)
            XCTAssertEqual(candidates.first?.externalSessionID, "candidate-a")
        } else {
            XCTFail("Expected .ambiguous, got \(decision)")
        }
    }

    func testClaudeActiveSessionResolverRebindsWhenLeaderDominatesByGap() {
        let launched = Date().addingTimeInterval(-30)
        let entry = ClaudeActiveSessionTrackerEntry(
            localSessionID: UUID(),
            projectCwd: "/tmp/repo",
            currentExternalID: "current",
            launchedAt: launched
        )
        let now = Date()
        let indexed = [
            makeIndexedClaudeSession(id: "leader", cwd: "/tmp/repo", lastActivityAt: now),
            // 5s zurueck → leader dominiert, automatischer Rebind erlaubt.
            makeIndexedClaudeSession(id: "stale", cwd: "/tmp/repo", lastActivityAt: now.addingTimeInterval(-5))
        ]
        let decision = ClaudeActiveSessionResolver.decide(entry: entry, indexedSessions: indexed)
        XCTAssertEqual(decision, .rebind(newExternalID: "leader", title: "Some Session"))
    }
}
