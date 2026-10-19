import XCTest
@testable import WhisperM8

/// LR-CLI-002: Kein Anhängen an einen getippten Entwurf.
/// LR-CLI-003: Keine Zustellung in einen noch startenden Chat.
final class PromptDeliveryGateTests: XCTestCase {
    func testQueueWaitsWhileLaunchingOrWithDraft() {
        XCTAssertEqual(PromptDeliveryGate.forQueue(runtime: .idle, lifecycle: .launching, mayHaveUnsentInput: false), .notReady)
        XCTAssertEqual(PromptDeliveryGate.forQueue(runtime: .idle, lifecycle: .ready, mayHaveUnsentInput: true), .draftPending)
        XCTAssertEqual(PromptDeliveryGate.forQueue(runtime: .working, lifecycle: .working, mayHaveUnsentInput: false), .busy("working"))
        XCTAssertEqual(PromptDeliveryGate.forQueue(runtime: .idle, lifecycle: .ready, mayHaveUnsentInput: false), .deliver)
        XCTAssertEqual(PromptDeliveryGate.forQueue(runtime: nil, lifecycle: nil, mayHaveUnsentInput: false), .deliver)
    }

    func testSendRefusesDraftUnlessForced() {
        XCTAssertTrue(PromptDeliveryGate.sendBlockedByDraft(mayHaveUnsentInput: true, force: false))
        XCTAssertFalse(PromptDeliveryGate.sendBlockedByDraft(mayHaveUnsentInput: true, force: true))
        XCTAssertFalse(PromptDeliveryGate.sendBlockedByDraft(mayHaveUnsentInput: false, force: false))
        XCTAssertTrue(PromptDeliveryGate.draftMessage.contains("enqueue"))
    }
}

/// LR-CLI-008: Der Kontowechsel bekam dieselbe 10-s-Frist wie jede Mutation.
final class ControlTimeoutTests: XCTestCase {
    func testLongRunningMethodsGetLongerTimeoutsAndClientWaitsLonger() {
        XCTAssertEqual(ChatsControlProtocol.handlerTimeoutSeconds(for: "session.send"), 10)
        XCTAssertGreaterThanOrEqual(ChatsControlProtocol.handlerTimeoutSeconds(for: "session.moveAccount"), 60)
        for method in ["session.send", "session.moveAccount", "session.close"] {
            XCTAssertGreaterThan(ChatsControlProtocol.clientReadTimeoutSeconds(for: method),
                                 ChatsControlProtocol.handlerTimeoutSeconds(for: method))
        }
    }
}

/// LR-CLI-012: Audit-Log und Queue mit Prompt-Inhalten nur für den eigenen Benutzer.
final class PrivateFilePermissionTests: XCTestCase {
    func testAuditLogAndQueueAreOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audit = dir.appendingPathComponent("chats-audit.jsonl")
        ChatsAuditLog(fileURL: audit).append(ChatsAuditEntry(
            at: Date(), actor: "x", verified: false, method: "send", target: nil, outcome: "ok",
            promptChars: 3, promptHead: "abc"))
        let queue = dir.appendingPathComponent("queue.json")
        try AgentPromptQueueStore(fileURL: queue).enqueue(sessionID: UUID(), prompt: "geheim", by: "x")
        for url in [audit, queue] {
            let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(perms?.intValue, 0o600, url.lastPathComponent)
        }
    }
}
