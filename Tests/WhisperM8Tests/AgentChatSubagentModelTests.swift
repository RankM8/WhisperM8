import XCTest
@testable import WhisperM8

final class AgentChatSubagentModelTests: XCTestCase {
    private func makeSession() -> AgentChatSession {
        AgentChatSession(
            provider: .codex,
            projectID: UUID(),
            externalSessionID: "thread-42",
            title: "Review OutputModeStore",
            hasLaunchedInitialPrompt: true,
            createdManually: true,
            kind: .subagentJob,
            subagentJobShortID: "a3f81c2e",
            subagentParentSessionID: "claude-parent-1",
            subagentCwd: "/tmp/jobs/a3f81c2e/worktree"
        )
    }

    func testRoundTripsSubagentFields() throws {
        let session = makeSession()
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentChatSession.self, from: data)
        XCTAssertEqual(decoded.kind, .subagentJob)
        XCTAssertTrue(decoded.isSubagentJob)
        XCTAssertEqual(decoded.subagentJobShortID, "a3f81c2e")
        XCTAssertEqual(decoded.subagentParentSessionID, "claude-parent-1")
        XCTAssertEqual(decoded.subagentCwd, "/tmp/jobs/a3f81c2e/worktree")
    }

    /// Downgrade-Schutz: ein kind-String aus einer NEUEREN App-Version darf
    /// den Decode nicht scheitern lassen (sonst verwirft das Repository den
    /// GESAMTEN Workspace) — er fällt auf .chat zurück.
    func testUnknownKindDecodesAsChatInsteadOfThrowing() throws {
        var session = makeSession()
        session.kind = nil
        var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(session)
        ) as! [String: Any]
        object["kind"] = "holographicAgent"
        let data = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AgentChatSession.self, from: data)
        XCTAssertNil(decoded.kind)
        XCTAssertEqual(decoded.effectiveKind, .chat)
    }

    func testLegacySessionWithoutSubagentFieldsDecodes() throws {
        let legacy = AgentChatSession(
            provider: .claude,
            projectID: UUID(),
            title: "Alt"
        )
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(AgentChatSession.self, from: data)
        XCTAssertNil(decoded.subagentJobShortID)
        XCTAssertNil(decoded.subagentParentSessionID)
        XCTAssertFalse(decoded.isSubagentJob)
    }

    func testLenientDecodeHelper() {
        XCTAssertEqual(AgentSessionKind.lenientDecode("subagentJob"), .subagentJob)
        XCTAssertEqual(AgentSessionKind.lenientDecode("chat"), .chat)
        XCTAssertNil(AgentSessionKind.lenientDecode("fromTheFuture"))
        XCTAssertNil(AgentSessionKind.lenientDecode(nil))
    }
}
