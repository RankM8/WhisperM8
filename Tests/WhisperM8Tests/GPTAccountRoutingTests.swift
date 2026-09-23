import Foundation
import XCTest
@testable import WhisperM8

/// Slice 2 der GPT-Konto-Profile: Stempel `gptProfileName` (Store-Default,
/// ausdrueckliche Wahl, Codable), Konto-Header im Launch-Env und die
/// Auswertung von `limit_reached` in der Usage-Antwort.
final class GPTAccountRoutingTests: XCTestCase {
    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8GPTAccountRouting-\(UUID().uuidString)")
            .appendingPathExtension("json")
    }

    private func makeStore(activeGPTProfile: String?, fileURL: URL) -> AgentSessionStore {
        var store = AgentSessionStore(fileURL: fileURL)
        store.activeClaudeProfileResolver = { nil }
        store.activeGPTProfileResolver = { activeGPTProfile }
        return store
    }

    // MARK: - Store

    func testClaudeSessionWithoutSelectionInheritsActiveGPTProfile() throws {
        let fileURL = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = makeStore(activeGPTProfile: "ai", fileURL: fileURL)

        let session = try store.createSession(
            provider: .claude,
            projectPath: FileManager.default.temporaryDirectory.path,
            title: "Ohne Angabe"
        )

        XCTAssertEqual(session.gptProfileName, "ai")
        XCTAssertNil(session.claudeProfileName)
    }

    func testExplicitMainWinsOverActiveGPTProfile() throws {
        let fileURL = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = makeStore(activeGPTProfile: "ai", fileURL: fileURL)

        let session = try store.createSession(
            provider: .claude,
            projectPath: FileManager.default.temporaryDirectory.path,
            title: "Ausdruecklich main",
            gptProfile: .explicit(nil)
        )

        XCTAssertNil(session.gptProfileName)
    }

    func testCodexSessionNeverGetsGPTProfileStamp() throws {
        let fileURL = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = makeStore(activeGPTProfile: "ai", fileURL: fileURL)

        let session = try store.createSession(
            provider: .codex,
            projectPath: FileManager.default.temporaryDirectory.path,
            title: "Codex",
            gptProfile: .explicit("ai")
        )

        XCTAssertNil(session.gptProfileName)
    }

    func testSetGPTSessionProfileRestampsOnlyClaudeSessionsInSelection() throws {
        let fileURL = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = makeStore(activeGPTProfile: nil, fileURL: fileURL)
        let path = FileManager.default.temporaryDirectory.path
        let a = try store.createSession(provider: .claude, projectPath: path, title: "A")
        let b = try store.createSession(provider: .claude, projectPath: path, title: "B")
        let c = try store.createSession(provider: .codex, projectPath: path, title: "C")

        try store.setGPTSessionProfile(ids: [a.id, c.id], profileName: "ai")

        let sessions = store.loadWorkspace().sessions
        XCTAssertEqual(sessions.first { $0.id == a.id }?.gptProfileName, "ai")
        XCTAssertNil(sessions.first { $0.id == b.id }?.gptProfileName)
        XCTAssertNil(sessions.first { $0.id == c.id }?.gptProfileName)

        try store.setGPTSessionProfile(ids: [a.id], profileName: nil)
        XCTAssertNil(store.loadWorkspace().sessions.first { $0.id == a.id }?.gptProfileName)
    }

    // MARK: - Modell

    func testGPTProfileNameSurvivesCodableRoundtrip() throws {
        let session = AgentChatSession(
            provider: .claude,
            projectID: UUID(),
            title: "Stempel",
            gptProfileName: "ai"
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentChatSession.self, from: data)
        XCTAssertEqual(decoded.gptProfileName, "ai")

        // Alte Workspace-Dateien ohne das Feld bleiben lesbar (nil = main).
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "gptProfileName")
        let legacy = try JSONDecoder().decode(
            AgentChatSession.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertNil(legacy.gptProfileName)
    }

    // MARK: - Launch-Env

    func testStampedSessionCarriesProfileHeaderInLaunchEnvironment() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.claudeProfileEnvironmentResolver = { _ in [:] }
        builder.gptBackendEnabledResolver = { true }
        builder.gptRouterPortResolver = { 19_002 }
        builder.gptPickerModelResolver = { "" }
        builder.gptSubagentModelResolver = { "" }
        builder.gptDefaultModelResolver = { "" }
        builder.gptProfileHeaderResolver = { $0 }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Claude",
            gptProfileName: "ai"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(
            command.environmentOverrides["ANTHROPIC_CUSTOM_HEADERS"],
            "X-WhisperM8-GPT-Profile: ai"
        )
        XCTAssertEqual(command.environmentOverrides["ANTHROPIC_BASE_URL"], "http://127.0.0.1:19002")
    }

    func testUnstampedSessionSendsExplicitMainHeaderWhenResolverSaysSo() throws {
        // B1: main muss ausdruecklich im Header stehen, sonst folgt der Chat
        // dem aktiven Profil.
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.claudeProfileEnvironmentResolver = { _ in [:] }
        builder.gptBackendEnabledResolver = { true }
        builder.gptRouterPortResolver = { 19_002 }
        builder.gptPickerModelResolver = { "" }
        builder.gptSubagentModelResolver = { "" }
        builder.gptDefaultModelResolver = { "" }
        builder.gptProfileHeaderResolver = { $0 ?? "main" }
        let session = AgentChatSession(provider: .claude, projectID: project.id, title: "Claude")

        let command = try builder.command(for: session, project: project)
        XCTAssertEqual(command.environmentOverrides["ANTHROPIC_CUSTOM_HEADERS"], "X-WhisperM8-GPT-Profile: main")

        // Ungueltiger Name aus dem Resolver landet nie im Header.
        builder.gptProfileHeaderResolver = { _ in "mein konto" }
        let odd = try builder.command(for: session, project: project)
        XCTAssertNil(odd.environmentOverrides["ANTHROPIC_CUSTOM_HEADERS"])
    }

    func testSetGPTSessionProfileRejectsInvalidNames() throws {
        let fileURL = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = makeStore(activeGPTProfile: nil, fileURL: fileURL)
        let a = try store.createSession(provider: .claude, projectPath: FileManager.default.temporaryDirectory.path, title: "A")
        XCTAssertThrowsError(try store.setGPTSessionProfile(ids: [a.id], profileName: "../x"))
        XCTAssertNil(store.loadWorkspace().sessions.first { $0.id == a.id }?.gptProfileName)
    }

    func testUnstampedSessionHasNoProfileHeader() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.claudeProfileEnvironmentResolver = { _ in [:] }
        builder.gptBackendEnabledResolver = { true }
        builder.gptRouterPortResolver = { 19_002 }
        builder.gptPickerModelResolver = { "" }
        builder.gptSubagentModelResolver = { "" }
        builder.gptDefaultModelResolver = { "" }
        var resolverCalls: [String?] = []
        builder.gptProfileHeaderResolver = { profile in
            resolverCalls.append(profile)
            return nil
        }
        let session = AgentChatSession(provider: .claude, projectID: project.id, title: "Claude")

        let command = try builder.command(for: session, project: project)

        XCTAssertNil(command.environmentOverrides["ANTHROPIC_CUSTOM_HEADERS"])
        XCTAssertEqual(resolverCalls, [nil])
    }

    // MARK: - Usage

    func testWhamUsageParsesLimitReachedAndAllowed() throws {
        let locked = Data("""
        {"plan_type":"prolite","email":"ai@example.com","rate_limit":{"allowed":false,"limit_reached":true,"primary_window":{"used_percent":100,"limit_window_seconds":604800,"reset_at":1790000000}}}
        """.utf8)
        let free = Data("""
        {"plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":12,"limit_window_seconds":604800,"reset_at":1790000000}}}
        """.utf8)
        let legacy = Data("""
        {"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":100,"limit_window_seconds":604800}}}
        """.utf8)

        XCTAssertEqual(CodexUsageFetcher.parseWhamUsage(locked, fetchedAt: Date())?.isLimitReached, true)
        XCTAssertEqual(CodexUsageFetcher.parseWhamUsage(free, fetchedAt: Date())?.isLimitReached, false)
        XCTAssertEqual(CodexUsageFetcher.parseWhamUsage(legacy, fetchedAt: Date())?.isLimitReached, false)
    }
}
