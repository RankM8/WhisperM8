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
        XCTAssertFalse(ChatsBoardCommand.needsWorkspace(options: ChatsBoardReadOptions(json: true), file: JarvisBoardFile(), callerSessionID: nil))
    }

    func testSelfWithEmptyBoardSkipsWorkspace() {
        XCTAssertFalse(ChatsBoardCommand.needsWorkspace(options: ChatsBoardReadOptions(json: true), file: file(withEntries: false), callerSessionID: nil))
    }

    func testFullUUIDAndAllSkipWorkspaceWithoutEntries() {
        let uuid = UUID().uuidString
        XCTAssertFalse(ChatsBoardCommand.needsWorkspace(options: ChatsBoardReadOptions(owner: uuid, json: true), file: JarvisBoardFile(), callerSessionID: nil))
        XCTAssertFalse(ChatsBoardCommand.needsWorkspace(options: ChatsBoardReadOptions(all: true, json: true), file: JarvisBoardFile(), callerSessionID: nil))
    }

    func testOwnBoardEntriesNeedWorkspaceForStatusRows() {
        let board = file(withEntries: true)
        let owner = board.boards[0].owner
        XCTAssertTrue(ChatsBoardCommand.needsWorkspace(options: ChatsBoardReadOptions(json: true), file: board, callerSessionID: owner))
        XCTAssertTrue(ChatsBoardCommand.needsWorkspace(
            options: ChatsBoardReadOptions(owner: owner.uuidString, json: true), file: board, callerSessionID: nil))
    }

    /// WM8-87: Ein Eintrag auf dem Board eines anderen Chats zwang jede
    /// Sitzung (alle 2 s) zum Laden der ganzen Chat-Liste.
    func testEntriesOnSomeoneElsesBoardDoNotLoadTheWorkspace() {
        let board = file(withEntries: true)
        XCTAssertFalse(ChatsBoardCommand.needsWorkspace(options: ChatsBoardReadOptions(json: true), file: board, callerSessionID: UUID()))
        XCTAssertFalse(ChatsBoardCommand.needsWorkspace(options: ChatsBoardReadOptions(json: true), file: board, callerSessionID: nil))
        XCTAssertFalse(ChatsBoardCommand.needsWorkspace(
            options: ChatsBoardReadOptions(owner: UUID().uuidString, json: true), file: board, callerSessionID: nil))
    }

    func testAllNeedsWorkspaceWhenAnyBoardHasEntries() {
        XCTAssertTrue(ChatsBoardCommand.needsWorkspace(
            options: ChatsBoardReadOptions(all: true, json: true), file: file(withEntries: true), callerSessionID: nil))
    }

    func testSessionRefOwnerNeedsWorkspaceToResolve() {
        XCTAssertTrue(ChatsBoardCommand.needsWorkspace(options: ChatsBoardReadOptions(owner: "a3f2c1d0"), file: JarvisBoardFile(), callerSessionID: nil))
    }
}
