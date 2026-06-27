import Foundation
import XCTest
@testable import WhisperM8

/// Phase-3 (S7-A): deckt die aus AgentChatsView extrahierten, rein
/// store-mutierenden Aktionen ab — gegen einen echten AgentSessionStore
/// (temp-Datei), ohne View.
@MainActor
final class AgentChatsViewModelTests: XCTestCase {
    private func makeStore() -> AgentSessionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("acvm-\(UUID().uuidString).json")
        return AgentSessionStore(fileURL: url)
    }

    func testRenameSessionUpdatesStore() throws {
        let store = makeStore()
        let session = try store.createSession(
            provider: .claude, projectPath: NSTemporaryDirectory() + "p", title: "Old Title"
        )
        let viewModel = AgentChatsViewModel(store: store)

        let error = viewModel.renameSession(id: session.id, title: "New Title")

        XCTAssertNil(error)
        XCTAssertEqual(
            store.loadWorkspace().sessions.first { $0.id == session.id }?.title,
            "New Title"
        )
    }

    func testSetSessionColorSucceeds() throws {
        let store = makeStore()
        let session = try store.createSession(
            provider: .claude, projectPath: NSTemporaryDirectory() + "p", title: "S"
        )
        let viewModel = AgentChatsViewModel(store: store)

        XCTAssertNil(viewModel.setSessionColor(id: session.id, color: "#FF8800"))
    }

    func testRenameProjectUpdatesStore() throws {
        let store = makeStore()
        let project = try store.upsertProject(
            path: NSTemporaryDirectory() + "proj-\(UUID().uuidString)", name: "Old", createdManually: true
        )
        let viewModel = AgentChatsViewModel(store: store)

        let error = viewModel.renameProject(id: project.id, name: "Renamed")

        XCTAssertNil(error)
        XCTAssertEqual(
            store.loadWorkspace().projects.first { $0.id == project.id }?.name,
            "Renamed"
        )
    }
}
