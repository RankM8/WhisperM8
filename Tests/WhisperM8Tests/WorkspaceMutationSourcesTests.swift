import XCTest
@testable import WhisperM8

/// Die Aufrufer einer Änderung am Chat-Bestand landen im Log, wenn
/// `workspace.apply` das Budget reißt (WM8-101).
final class WorkspaceMutationSourcesTests: XCTestCase {
    private var savedGate: Bool!

    override func setUp() {
        super.setUp()
        savedGate = PerfDetailGate.isEnabled
        _ = WorkspaceMutationSources.shared.drain()
    }

    override func tearDown() {
        _ = WorkspaceMutationSources.shared.drain()
        PerfDetailGate.isEnabled = savedGate
        super.tearDown()
    }

    func testChangingMutationRecordsItsCaller() throws {
        PerfDetailGate.isEnabled = true
        let store = AgentWorkspaceStore(loadInitial: { .empty }, persist: { _ in })
        let session = AgentChatSession(provider: .claude, projectID: UUID(), title: "Chat", createdManually: true)

        try store.mutate { $0.sessions.append(session) }
        try store.mutateIfChanged { workspace in
            workspace.sessions[0].title = "Neu"
            return true
        }

        let sources = WorkspaceMutationSources.shared.drain()
        XCTAssertEqual(sources, ["testChangingMutationRecordsItsCaller()": 2])
        XCTAssertEqual(WorkspaceMutationSources.shared.drain(), [:], "Abholen leert die Liste")
    }

    func testNoOpMutationRecordsNothing() throws {
        PerfDetailGate.isEnabled = true
        let store = AgentWorkspaceStore(loadInitial: { .empty }, persist: { _ in })

        try store.mutate { $0.sessions = $0.sessions }
        try store.mutateIfChanged { _ in false }

        XCTAssertEqual(WorkspaceMutationSources.shared.drain(), [:])
    }

    func testRecordsNothingWithoutDetailTier() throws {
        PerfDetailGate.isEnabled = false
        let store = AgentWorkspaceStore(loadInitial: { .empty }, persist: { _ in })
        let session = AgentChatSession(provider: .claude, projectID: UUID(), title: "Chat", createdManually: true)

        try store.mutate { $0.sessions.append(session) }

        XCTAssertEqual(WorkspaceMutationSources.shared.drain(), [:])
    }

    func testFacadePassesItsOwnCallerThrough() throws {
        PerfDetailGate.isEnabled = true
        let store = AgentWorkspaceStore(loadInitial: { .empty }, persist: { _ in })
        let session = AgentChatSession(provider: .claude, projectID: UUID(), title: "Chat", createdManually: true)

        try store.mutate(caller: "renameSession(_:to:)") { $0.sessions.append(session) }

        XCTAssertEqual(WorkspaceMutationSources.shared.drain(), ["renameSession(_:to:)": 1])
    }

    func testDescribeIsStableAndCountsRepeats() {
        XCTAssertEqual(WorkspaceMutationSources.describe([:]), "-")
        XCTAssertEqual(
            WorkspaceMutationSources.describe(["b()": 1, "a()": 1, "touch(_:)": 3]),
            "touch(_:)×3,a(),b()")
    }
}
