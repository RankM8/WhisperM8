import XCTest
@testable import WhisperM8

/// Rückfall-Bindung neuer Chats (Befund 13.11.2026, Test-Instanz): „soak bash“
/// und „soak question“ starteten 3 s nacheinander im selben Ordner. Der Poller
/// des zweiten band das jüngste Transcript im Ordner (cd00c6c0) — das des
/// ersten. Beide Chats trugen danach dieselbe Claude-Sitzung.
final class AgentFallbackBindingTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8FallbackBinding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func indexed(_ id: String, cwd: String, createdAt: Date, provider: AgentProvider = .claude) -> IndexedAgentSession {
        IndexedAgentSession(provider: provider, externalSessionID: id, cwd: cwd, title: "Transcript \(id)",
                            model: nil, reasoningEffort: nil, createdAt: createdAt, lastActivityAt: createdAt)
    }

    /// Zwei Chats im selben Ordner, der erste gebunden; Zeiten wie im Beleg.
    private func makeStoreWithSoakChats() throws -> (store: AgentSessionStore, bash: AgentChatSession, question: AgentChatSession, t0: Date) {
        let store = AgentSessionStore(fileURL: tempDir.appendingPathComponent("workspace.json"))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var bash = try store.createSession(provider: .claude, projectPath: tempDir.path, title: "soak bash")
        bash.createdAt = t0
        bash.externalSessionID = "cd00c6c0"
        bash.status = .running
        _ = try store.upsertSession(bash)
        var question = try store.createSession(provider: .claude, projectPath: tempDir.path, title: "soak question")
        question.createdAt = t0.addingTimeInterval(3)
        question.status = .running
        _ = try store.upsertSession(question)
        return (store, bash, question, t0)
    }

    func testFallbackNeverBindsTranscriptOfAnotherChat() throws {
        let (store, _, question, t0) = try makeStoreWithSoakChats()
        // Transcript des ersten Chats, geschrieben NACH dem Start des zweiten.
        let foreign = indexed("cd00c6c0", cwd: tempDir.path, createdAt: t0.addingTimeInterval(3.5))

        let bound = try store.bindLatestIndexedSession(
            localSessionID: question.id, provider: .claude, projectPath: tempDir.path, indexedSessions: [foreign])

        XCTAssertNil(bound, "fremdes Transcript gebunden")
        XCTAssertNil(store.loadWorkspace().sessions.first(where: { $0.id == question.id })?.externalSessionID)
    }

    func testFallbackBindsOwnTranscriptNextToForeignOne() throws {
        let (store, _, question, t0) = try makeStoreWithSoakChats()
        let foreign = indexed("cd00c6c0", cwd: tempDir.path, createdAt: t0.addingTimeInterval(3.5))
        let own = indexed("aa82d0ba", cwd: tempDir.path, createdAt: t0.addingTimeInterval(3.2))

        let bound = try store.bindLatestIndexedSession(
            localSessionID: question.id, provider: .claude, projectPath: tempDir.path,
            indexedSessions: [foreign, own])

        XCTAssertEqual(bound?.externalSessionID, "aa82d0ba")
    }

    func testFallbackMatchesBoundIDsCaseInsensitively() throws {
        let (store, _, question, t0) = try makeStoreWithSoakChats()
        let foreign = indexed("CD00C6C0", cwd: tempDir.path, createdAt: t0.addingTimeInterval(3.5))
        XCTAssertNil(try store.bindLatestIndexedSession(
            localSessionID: question.id, provider: .claude, projectPath: tempDir.path, indexedSessions: [foreign]))
    }

    func testFallbackWaitsForHookWhileTwoChatsStartTogether() throws {
        // Beide noch ungebunden: welches Transcript zu wem gehört, weiß nur der Hook.
        let (store, bash, question, t0) = try makeStoreWithSoakChats()
        var unbound = bash
        unbound.externalSessionID = nil
        _ = try store.upsertSession(unbound)
        let transcript = indexed("cd00c6c0", cwd: tempDir.path, createdAt: t0.addingTimeInterval(3.5))

        for chat in [bash, question] {
            XCTAssertNil(try store.bindLatestIndexedSession(
                localSessionID: chat.id, provider: .claude, projectPath: tempDir.path, indexedSessions: [transcript]))
        }
    }

    func testRivalOutsideWindowOrElsewhereDoesNotBlock() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let here = AgentProject(name: "hier", path: tempDir.path)
        let other = AgentProject(name: "dort", path: tempDir.appendingPathComponent("dort").path)
        let chat = AgentChatSession(provider: .claude, projectID: here.id, title: "neu", createdAt: t0)
        let old = AgentChatSession(provider: .claude, projectID: here.id, title: "alt", createdAt: t0.addingTimeInterval(-120))
        let elsewhere = AgentChatSession(provider: .claude, projectID: other.id, title: "anderswo", createdAt: t0)
        let codex = AgentChatSession(provider: .codex, projectID: here.id, title: "codex", createdAt: t0)
        let workspace = AgentWorkspace(projects: [here, other], sessions: [chat, old, elsewhere, codex])

        let candidate = AgentSessionStore.fallbackBindingCandidate(
            for: chat, projectPath: tempDir.path, provider: .claude, workspace: workspace,
            indexedSessions: [indexed("eigen", cwd: tempDir.path, createdAt: t0.addingTimeInterval(1))])

        XCTAssertEqual(candidate?.externalSessionID, "eigen")
    }
}
