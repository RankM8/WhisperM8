import Darwin
import XCTest
@testable import WhisperM8

/// Befund D (11.11.2026): Claudes Daemon und alle Hintergrund-Agents erbten
/// WHISPERM8_SESSION_ID/_TOKEN des Chats, der den Daemon gestartet hat.
final class AgentCallerIdentityCheckTests: XCTestCase {
    private let fin = UUID()
    private let jarvisCopy = UUID()
    private let finExternal = "1f353dce-783f-407c-a2d4-402c5e884d59"
    private let copyExternal = "84ca7666-c23f-4547-9dba-d8e020792b32"

    private func record(_ sessionID: String, kind: String) -> ClaudeSessionRecord {
        ClaudeSessionRecord(profileName: "main", pid: 67815, sessionID: sessionID, kind: kind)
    }

    private func verdict(claimed: UUID?, record: ClaudeSessionRecord?) -> AgentCallerIdentityCheck.Verdict {
        let external: [UUID: String] = [fin: finExternal, jarvisCopy: copyExternal]
        return AgentCallerIdentityCheck.verdict(
            claimed: claimed, record: record,
            externalSessionIDOf: { external[$0] },
            sessionForExternalID: { id in external.first { $0.value == id.lowercased() }?.key })
    }

    func testInteractiveChatsAndCallersOutsideClaudeKeepTheirIdentity() {
        XCTAssertEqual(verdict(claimed: fin, record: record(finExternal, kind: "interactive")), .keep)
        XCTAssertEqual(verdict(claimed: fin, record: nil), .keep, "kein Claude-Prozess in der Kette")
    }

    func testBackgroundAgentWithItsOwnIdentityKeepsIt() {
        XCTAssertEqual(verdict(claimed: fin, record: record(finExternal.uppercased(), kind: "bg")), .keep)
    }

    func testBackgroundAgentWithInheritedIdentityBecomesItsOwnChat() {
        // Die Jarvis-Kopie trug Fins Umgebung.
        XCTAssertEqual(verdict(claimed: fin, record: record(copyExternal, kind: "bg")), .replace(jarvisCopy))
        XCTAssertEqual(verdict(claimed: nil, record: record(copyExternal, kind: "bg")), .replace(jarvisCopy))
    }

    func testBackgroundAgentWithoutChatIsExternal() {
        XCTAssertEqual(verdict(claimed: fin, record: record("ffffffff-0000-0000-0000-000000000000", kind: "bg")),
                       .replace(nil))
        XCTAssertEqual(verdict(claimed: nil, record: record("ffffffff-0000-0000-0000-000000000000", kind: "bg")),
                       .keep, "nichts behauptet, nichts zu korrigieren")
    }

    func testNearestClaudeRecordWalksUpTheProcessChain() {
        // CLI 300 → Shell 200 → Claude 100 → launchd 1
        let parents: [Int32: Int32] = [300: 200, 200: 100, 100: 1]
        let claude = record(copyExternal, kind: "bg")
        let found = AgentCallerIdentityCheck.nearestClaudeRecord(
            startingAt: 300, parentOf: { parents[$0] }, recordFor: { $0 == 100 ? claude : nil })
        XCTAssertEqual(found, claude)
        XCTAssertNil(AgentCallerIdentityCheck.nearestClaudeRecord(
            startingAt: 300, parentOf: { parents[$0] }, recordFor: { _ in nil }))
    }

    func testLookupsPreferTheManualChatForDuplicates() {
        let project = UUID()
        let auto = AgentChatSession(provider: .claude, projectID: project, externalSessionID: finExternal,
                                    title: "Auto", status: .closed, hasLaunchedInitialPrompt: true)
        let manual = AgentChatSession(provider: .claude, projectID: project, externalSessionID: finExternal,
                                      title: "Fin", status: .closed, hasLaunchedInitialPrompt: true,
                                      createdManually: true)
        let lookup = AgentCallerIdentityCheck.lookups(sessions: [auto, manual])
        XCTAssertEqual(lookup.sessionForExternalID(finExternal.uppercased()), manual.id)
    }

    /// Review-Befund: Ohne Registry-Eintrag (Worker-Start, bg-pty-host,
    /// verwaiste Kinder) galt die geerbte Identität samt gültigem Token weiter.
    /// Jetzt zählt nur, ob die PTY des Chats in der Prozesskette steht.
    func testTokenCountsOnlyWithThePtyInTheCallersProcessChain() {
        let request = ChatsControlRequest(actor: ChatsControlActor(sessionID: fin.uuidString, token: "fins-token"),
                                          method: "session.send", params: .object([:]))
        // CLI 300 → Shell 200 → Claude 100 (Fins PTY)
        let fromFinsTab = AgentControlServer.corrected(request, claimed: fin, ptyPID: 100, chain: [300, 200, 100])
        XCTAssertEqual(fromFinsTab.actor, request.actor)

        // CLI 900 → Shell 800 → bg-spare 67815 → bg-pty-host 67732 → Daemon 73520
        let fromDaemonChild = AgentControlServer.corrected(request, claimed: fin, ptyPID: 100,
                                                          chain: [900, 800, 67815, 67732, 73520])
        XCTAssertEqual(fromDaemonChild.actor, ChatsControlActor(), "geerbte Identität fällt raus")
        XCTAssertFalse(AgentControlRequestHandler.rejectsUnverifiedActor(fromDaemonChild), "extern bleibt erlaubt")
    }

    func testProcessChainStopsAtLaunchd() {
        let parents: [Int32: Int32] = [300: 200, 200: 100, 100: 1]
        XCTAssertEqual(AgentCallerIdentityCheck.processChain(startingAt: 300, parentOf: { parents[$0] }), [300, 200, 100])
        XCTAssertEqual(AgentCallerIdentityCheck.processChain(startingAt: getpid()).first, getpid())
    }

    func testTokenRegistryForgetsThePtyWithTheToken() {
        let registry = AgentSessionTokenRegistry.shared
        let id = UUID()
        let token = registry.issueToken(for: id)
        registry.bindProcess(sessionID: id, pid: 4242, isAttach: true)
        XCTAssertEqual(registry.processID(for: id), 4242)
        XCTAssertTrue(registry.attachSessionIDs().contains(id))
        registry.revoke(sessionID: id, ifToken: token)
        XCTAssertNil(registry.processID(for: id))
        XCTAssertFalse(registry.attachSessionIDs().contains(id))
    }

    func testProcessHelpersReadTheRealKernelState() throws {
        XCTAssertEqual(AgentCallerIdentityCheck.parentProcessID(of: getpid()), getppid())
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        XCTAssertEqual(AgentCallerIdentityCheck.peerProcessID(socket: fds[0]), getpid())
    }
}
