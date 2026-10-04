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
}
