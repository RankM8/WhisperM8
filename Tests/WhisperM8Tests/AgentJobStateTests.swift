import XCTest
@testable import WhisperM8

final class AgentJobStateTests: XCTestCase {
    private func makeState(_ state: AgentJobState.State = .spawning) -> AgentJobState {
        var job = AgentJobState(
            shortId: "a3f81c2e",
            state: state,
            intent: "fix the bug",
            cwd: "/tmp/project",
            sandbox: .workspaceWrite
        )
        job.codexThreadID = "thread-1"
        return job
    }

    // MARK: - Codable

    func testRoundTrip() throws {
        var job = makeState(.running)
        job.supervisorPid = 4711
        job.worktree = .init(path: "/tmp/wt", branch: "subagent/a3f81c2e")
        job.metrics = .init(lastTurnSeconds: 12.5, diffChangedFiles: 3, diffAdded: 40, diffDeleted: 7)

        let data = try AgentJobStore.encode(job)
        let decoded = try XCTUnwrap(AgentJobStore.decode(data))
        // updatedAt/createdAt via ISO-8601 → Sekunden-Auflösung; Vergleich
        // feldweise statt Equatable auf dem Ganzen.
        XCTAssertEqual(decoded.shortId, job.shortId)
        XCTAssertEqual(decoded.state, .running)
        XCTAssertEqual(decoded.supervisorPid, 4711)
        XCTAssertEqual(decoded.worktree, job.worktree)
        XCTAssertEqual(decoded.metrics, job.metrics)
        XCTAssertEqual(decoded.codexThreadID, "thread-1")
    }

    func testUnknownStateFailsDecode() {
        let json = """
        {"version":1,"shortId":"x","provider":"codex","state":"exploded","intent":"i","cwd":"/tmp","turns":0,"sandbox":"workspace-write","createdAt":"2026-07-04T10:00:00Z","updatedAt":"2026-07-04T10:00:00Z"}
        """
        XCTAssertNil(AgentJobStore.decode(Data(json.utf8)))
    }

    func testNewerVersionIsTreatedAsUnreadable() throws {
        var job = makeState()
        job.version = AgentJobState.currentVersion + 1
        let data = try AgentJobStore.encode(job)
        XCTAssertNil(AgentJobStore.decode(data))
    }

    // MARK: - Transition-Tabelle

    func testAllowedTransitions() {
        XCTAssertTrue(AgentJobState.canTransition(from: .spawning, to: .running))
        XCTAssertTrue(AgentJobState.canTransition(from: .running, to: .done))
        XCTAssertTrue(AgentJobState.canTransition(from: .running, to: .failed))
        XCTAssertTrue(AgentJobState.canTransition(from: .running, to: .stopped))
        XCTAssertTrue(AgentJobState.canTransition(from: .running, to: .takenOver))
        // send auf abgeschlossenen Jobs:
        XCTAssertTrue(AgentJobState.canTransition(from: .done, to: .running))
        XCTAssertTrue(AgentJobState.canTransition(from: .failed, to: .running))
        XCTAssertTrue(AgentJobState.canTransition(from: .stopped, to: .running))
        // Übernahme aus Ruhezuständen:
        XCTAssertTrue(AgentJobState.canTransition(from: .done, to: .takenOver))
        // send-Claim reserviert ruhende Jobs auf spawning (TOCTOU-Schutz):
        XCTAssertTrue(AgentJobState.canTransition(from: .done, to: .spawning))
        XCTAssertTrue(AgentJobState.canTransition(from: .failed, to: .spawning))
        XCTAssertTrue(AgentJobState.canTransition(from: .stopped, to: .spawning))
    }

    func testForbiddenTransitions() {
        // takenOver ist terminal.
        XCTAssertFalse(AgentJobState.canTransition(from: .takenOver, to: .running))
        XCTAssertFalse(AgentJobState.canTransition(from: .takenOver, to: .done))
        // Aktive Jobs dürfen nicht erneut reserviert werden — genau das
        // prallt einen zweiten parallelen send ab.
        XCTAssertFalse(AgentJobState.canTransition(from: .running, to: .spawning))
        XCTAssertFalse(AgentJobState.canTransition(from: .spawning, to: .spawning))
        // spawning darf nicht direkt fertig sein.
        XCTAssertFalse(AgentJobState.canTransition(from: .spawning, to: .done))
    }

    func testIsActive() {
        XCTAssertTrue(makeState(.spawning).isActive)
        XCTAssertTrue(makeState(.running).isActive)
        XCTAssertFalse(makeState(.done).isActive)
        XCTAssertFalse(makeState(.takenOver).isActive)
    }
}
