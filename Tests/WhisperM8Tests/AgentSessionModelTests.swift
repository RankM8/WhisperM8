import Foundation
import XCTest
@testable import WhisperM8

final class AgentSessionModelTests: XCTestCase {
    func testAgentSessionKindRoundTripsViaJSON() throws {
        let projectID = UUID()
        let session = AgentChatSession(
            provider: .claude,
            projectID: projectID,
            title: "View",
            kind: .agentView
        )
        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentChatSession.self, from: encoded)
        XCTAssertEqual(decoded.kind, .agentView)
        XCTAssertEqual(decoded.effectiveKind, .agentView)
        XCTAssertTrue(decoded.isAgentView)
    }

    func testAgentSessionBackgroundFieldsRoundTripViaJSON() throws {
        let session = AgentChatSession(
            provider: .claude,
            projectID: UUID(),
            title: "BG",
            kind: .backgroundChat,
            backgroundShortID: "abc123",
            backgroundSubAgent: "code-reviewer",
            backgroundPermissionMode: "acceptEdits"
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentChatSession.self, from: data)
        XCTAssertEqual(decoded.kind, .backgroundChat)
        XCTAssertTrue(decoded.isBackgroundChat)
        XCTAssertEqual(decoded.backgroundShortID, "abc123")
        XCTAssertEqual(decoded.backgroundSubAgent, "code-reviewer")
        XCTAssertEqual(decoded.backgroundPermissionMode, "acceptEdits")
        XCTAssertTrue(decoded.hasBackgroundShortID)
    }

    func testAgentSessionLegacyJSONHasNilBackgroundFields() throws {
        let id = UUID()
        let projectID = UUID()
        let json = """
        {
          "id":"\(id.uuidString)",
          "provider":"claude",
          "projectID":"\(projectID.uuidString)",
          "title":"Legacy",
          "model":"x",
          "reasoningEffort":"medium",
          "status":"pending",
          "imagePaths":[],
          "hasLaunchedInitialPrompt":false,
          "createdAt":"2026-01-01T00:00:00Z",
          "lastActivityAt":"2026-01-01T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(AgentChatSession.self, from: json.data(using: .utf8)!)
        XCTAssertNil(session.backgroundShortID)
        XCTAssertNil(session.backgroundSubAgent)
        XCTAssertNil(session.backgroundPermissionMode)
        XCTAssertFalse(session.hasBackgroundShortID)
        XCTAssertFalse(session.isBackgroundChat)
    }

    func testAgentSessionKindLegacyJSONDefaultsToChat() throws {
        // Eine Legacy-Session-JSON ohne kind-Feld muss als .chat dekodiert
        // werden (decodeIfPresent ist Schema-evolution-friendly).
        let id = UUID()
        let projectID = UUID()
        let json = """
        {
          "id":"\(id.uuidString)",
          "provider":"claude",
          "projectID":"\(projectID.uuidString)",
          "title":"Legacy",
          "model":"x",
          "reasoningEffort":"medium",
          "status":"pending",
          "imagePaths":[],
          "hasLaunchedInitialPrompt":false,
          "createdAt":"2026-01-01T00:00:00Z",
          "lastActivityAt":"2026-01-01T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(AgentChatSession.self, from: json.data(using: .utf8)!)
        XCTAssertNil(session.kind)
        XCTAssertEqual(session.effectiveKind, .chat)
        XCTAssertFalse(session.isAgentView)
    }

    func testClaudeRuntimeDisplayDoesNotUseCodexModel() {
        let claude = AgentChatSession(
            provider: .claude,
            projectID: UUID(),
            title: "Claude Chat",
            model: "gpt-5.5"
        )
        let codex = AgentChatSession(
            provider: .codex,
            projectID: UUID(),
            title: "Codex Chat",
            model: "gpt-5.5",
            reasoningEffort: "medium"
        )

        XCTAssertEqual(claude.runtimeDisplayText, "Claude · Claude Code")
        XCTAssertEqual(codex.runtimeDisplayText, "Codex · gpt-5.5 · medium")
    }
}
