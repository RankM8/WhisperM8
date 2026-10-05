import XCTest
@testable import WhisperM8

/// ⌃⌥Tab: Reihenfolge und Rotation beim Sprung zum nächsten wartenden Chat.
final class NextWaitingChatResolverTests: XCTestCase {
    private typealias Candidate = NextWaitingChatResolver.Candidate

    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func waiting(_ id: UUID, since offset: TimeInterval?, archived: Bool = false) -> Candidate {
        Candidate(
            id: id,
            isArchived: archived,
            status: .awaitingInput,
            statusSince: offset.map { base.addingTimeInterval($0) }
        )
    }

    private func other(_ id: UUID, _ status: AgentSessionRuntimeStatus?) -> Candidate {
        Candidate(id: id, isArchived: false, status: status, statusSince: base)
    }

    // MARK: - Reihenfolge

    func testSortsLongestWaitingFirst() {
        let candidates = [waiting(a, since: 30), waiting(b, since: 10), waiting(c, since: 20)]
        XCTAssertEqual(NextWaitingChatResolver.order(candidates), [b, c, a])
    }

    func testMissingStatusSinceGoesLastAndStaysStable() {
        let candidates = [
            waiting(a, since: nil), waiting(b, since: 20), waiting(c, since: nil), waiting(d, since: 10),
        ]
        XCTAssertEqual(NextWaitingChatResolver.order(candidates), [d, b, a, c])
    }

    func testEqualStatusSinceKeepsInputOrder() {
        let candidates = [waiting(c, since: 5), waiting(a, since: 5), waiting(b, since: 5)]
        XCTAssertEqual(NextWaitingChatResolver.order(candidates), [c, a, b])
    }

    func testOnlyAwaitingInputCounts() {
        let candidates = [
            other(a, .working), other(b, .idle), other(c, nil), waiting(d, since: 0),
        ]
        XCTAssertEqual(NextWaitingChatResolver.order(candidates), [d])
    }

    func testArchivedIsExcluded() {
        let candidates = [waiting(a, since: 0, archived: true), waiting(b, since: 10)]
        XCTAssertEqual(NextWaitingChatResolver.order(candidates), [b])
        XCTAssertEqual(NextWaitingChatResolver.next(candidates: candidates, current: nil), b)
    }

    // MARK: - Sprungziel und Rotation

    func testNoneWaitingReturnsNil() {
        let candidates = [other(a, .working), other(b, .idle)]
        XCTAssertNil(NextWaitingChatResolver.next(candidates: candidates, current: a))
        XCTAssertNil(NextWaitingChatResolver.next(candidates: [], current: nil))
    }

    func testCurrentNotWaitingJumpsToLongestWaiting() {
        let candidates = [other(a, .working), waiting(b, since: 20), waiting(c, since: 10)]
        XCTAssertEqual(NextWaitingChatResolver.next(candidates: candidates, current: a), c)
        XCTAssertEqual(NextWaitingChatResolver.next(candidates: candidates, current: nil), c)
    }

    func testCurrentWaitingRotatesToNextWithWrapAround() {
        let candidates = [waiting(a, since: 10), waiting(b, since: 20), waiting(c, since: 30)]
        XCTAssertEqual(NextWaitingChatResolver.next(candidates: candidates, current: a), b)
        XCTAssertEqual(NextWaitingChatResolver.next(candidates: candidates, current: b), c)
        XCTAssertEqual(NextWaitingChatResolver.next(candidates: candidates, current: c), a)
    }

    func testCurrentIsOnlyWaitingChatReturnsNil() {
        let candidates = [waiting(a, since: 10), other(b, .working)]
        XCTAssertNil(NextWaitingChatResolver.next(candidates: candidates, current: a))
    }

    func testArchivedCurrentStartsAtLongestWaiting() {
        // Archivierter aktueller Chat zählt nicht zur Rotation.
        let candidates = [waiting(a, since: 0, archived: true), waiting(b, since: 20), waiting(c, since: 10)]
        XCTAssertEqual(NextWaitingChatResolver.next(candidates: candidates, current: a), c)
    }

    // MARK: - Kandidaten aus dem Status-Store (nur Wartende)

    /// Früherer Weg im Key-Event-Pfad: ein Kandidat je Session des Workspace.
    private func allSessionCandidates(
        _ sessions: [AgentChatSession],
        statuses: [UUID: AgentSessionRuntimeStatus],
        since: [UUID: Date]
    ) -> [Candidate] {
        sessions.map {
            Candidate(id: $0.id, isArchived: $0.status == .archived,
                      status: statuses[$0.id], statusSince: since[$0.id])
        }
    }

    func testCandidatesFromStatusStoreMatchFullScan() {
        let project = UUID()
        func session(_ status: AgentChatStatus = .running) -> AgentChatSession {
            AgentChatSession(provider: .claude, projectID: project, title: "t", status: status)
        }
        let sessions = [session(), session(.archived), session(), session(), session(), session()]
        let ids = sessions.map(\.id)
        let statuses: [UUID: AgentSessionRuntimeStatus] = [
            ids[0]: .idle,
            ids[1]: .awaitingInput, // archiviert
            ids[2]: .awaitingInput,
            ids[3]: .working,
            ids[4]: .awaitingInput,
            ids[5]: .awaitingInput,
            UUID(): .awaitingInput, // Status ohne Session im Workspace
        ]
        // ids[4] und ids[5] mit gleichem Zeitpunkt: der Gleichstand hängt an
        // der Eingangsreihenfolge und muss erhalten bleiben.
        let since: [UUID: Date] = [
            ids[1]: base, ids[2]: base.addingTimeInterval(30),
            ids[4]: base.addingTimeInterval(10), ids[5]: base.addingTimeInterval(10),
        ]

        let fast = NextWaitingChatResolver.candidates(
            statuses: statuses, sessions: sessions, statusSince: { since[$0] }
        )
        let full = allSessionCandidates(sessions, statuses: statuses, since: since)

        XCTAssertEqual(fast.map(\.id), [ids[1], ids[2], ids[4], ids[5]], "Nur Wartende, Workspace-Reihenfolge")
        XCTAssertEqual(NextWaitingChatResolver.order(fast), NextWaitingChatResolver.order(full))
        XCTAssertEqual(NextWaitingChatResolver.order(fast), [ids[4], ids[5], ids[2]])
        for current in ids + [nil] {
            XCTAssertEqual(
                NextWaitingChatResolver.next(candidates: fast, current: current),
                NextWaitingChatResolver.next(candidates: full, current: current)
            )
        }
    }

    func testCandidatesWithoutWaitingAreEmpty() {
        let sessions = [AgentChatSession(provider: .claude, projectID: UUID(), title: "t", status: .running)]
        let candidates = NextWaitingChatResolver.candidates(
            statuses: [sessions[0].id: .working], sessions: sessions, statusSince: { _ in nil }
        )
        XCTAssertTrue(candidates.isEmpty)
    }
}
