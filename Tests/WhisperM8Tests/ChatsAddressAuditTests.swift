import XCTest
@testable import WhisperM8

/// `chats address` hinterlässt eine Audit-Spur und kennt den Selbstschutz (LR-CLI-007).
final class ChatsAddressAuditTests: XCTestCase {
    func testAddressLookupIsAuditedWithoutPromptContent() async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let handler = AgentControlRequestHandler()
        handler.auditLog = ChatsAuditLog(fileURL: file)
        let target = UUID()

        let ok = await handler.handle(ChatsControlRequest(
            actor: ChatsControlActor(), method: "audit.note",
            params: .object(["targetSessionID": .string(target.uuidString)])))

        XCTAssertTrue(ok.ok)
        let entries = handler.auditLog.recent(limit: 10)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.method, "address")
        XCTAssertEqual(entries.first?.target, target.uuidString)
        XCTAssertNil(entries.first?.promptChars)
    }

    func testOwnAddressIsRefusedAndAudited() async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let handler = AgentControlRequestHandler()
        handler.auditLog = ChatsAuditLog(fileURL: file)
        let me = UUID()
        let token = AgentSessionTokenRegistry.shared.issueToken(for: me)
        defer { AgentSessionTokenRegistry.shared.revoke(sessionID: me) }

        let response = await handler.handle(ChatsControlRequest(
            actor: ChatsControlActor(sessionID: me.uuidString, token: token), method: "audit.note",
            params: .object(["targetSessionID": .string(me.uuidString)])))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, ChatsControlErrorCode.selfSend.rawValue)
        XCTAssertEqual(handler.auditLog.recent(limit: 10).first?.outcome, "selfSend")
    }
}
