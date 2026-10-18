import Foundation
import XCTest
@testable import WhisperM8

/// LR-PJ-003: `chats board --json` (läuft in jedem Chat beim Start) lädt ohne
/// Board-Eintrag den Workspace nicht.
final class ChatsBoardWorkspaceLoadTests: XCTestCase {
    private func file(withEntries: Bool) -> JarvisBoardFile {
        let entries = withEntries
            ? [JarvisBoardEntry(sessionID: UUID(), light: .running, updatedAt: Date())]
            : []
        return JarvisBoardFile(boards: [JarvisBoard(owner: UUID(), isActive: true, updatedAt: Date(), entries: entries)])
    }

    func testSelfWithoutBoardFileSkipsWorkspace() {
        XCTAssertFalse(ChatsBoardCommand.needsWorkspace(options: ChatsBoardReadOptions(json: true), file: JarvisBoardFile()))
    }

    func testSelfWithEmptyBoardSkipsWorkspace() {
        XCTAssertFalse(ChatsBoardCommand.needsWorkspace(options: ChatsBoardReadOptions(json: true), file: file(withEntries: false)))
    }

    func testFullUUIDAndAllSkipWorkspaceWithoutEntries() {
        let uuid = UUID().uuidString
        XCTAssertFalse(ChatsBoardCommand.needsWorkspace(options: ChatsBoardReadOptions(owner: uuid, json: true), file: JarvisBoardFile()))
        XCTAssertFalse(ChatsBoardCommand.needsWorkspace(options: ChatsBoardReadOptions(all: true, json: true), file: JarvisBoardFile()))
    }

    func testBoardEntriesNeedWorkspaceForStatusRows() {
        XCTAssertTrue(ChatsBoardCommand.needsWorkspace(options: ChatsBoardReadOptions(json: true), file: file(withEntries: true)))
    }

    func testSessionRefOwnerNeedsWorkspaceToResolve() {
        XCTAssertTrue(ChatsBoardCommand.needsWorkspace(options: ChatsBoardReadOptions(owner: "a3f2c1d0"), file: JarvisBoardFile()))
    }
}
