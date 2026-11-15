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

    // MARK: Sichtbar leeres Feld (WM8-64)

    /// 15.11.2026: Ein ruhender Chat mit laufendem Hintergrund-Befehl hatte ein
    /// leeres Feld, die Tasten-Schätzung vermutete trotzdem einen Entwurf.
    /// `send` merkte nur vor, die Warteschlange stellte nie zu. Ein am
    /// Bildschirm sichtbar leeres Feld schlägt die Schätzung.
    func testVisiblyEmptyFieldBeatsTrackerGuess() {
        XCTAssertEqual(PromptDeliveryGate.forQueue(runtime: .idle, lifecycle: .ready, mayHaveUnsentInput: true,
                                                   fieldVisiblyEmpty: true), .deliver)
        XCTAssertFalse(PromptDeliveryGate.sendBlockedByDraft(mayHaveUnsentInput: true, force: false, fieldVisiblyEmpty: true))
        // Sichtbarer Text bleibt ein Entwurf, ein arbeitender Chat bleibt beschäftigt.
        XCTAssertEqual(PromptDeliveryGate.forQueue(runtime: .idle, lifecycle: .ready, mayHaveUnsentInput: true,
                                                   visibleDraft: true, fieldVisiblyEmpty: false), .draftPending)
        XCTAssertEqual(PromptDeliveryGate.forQueue(runtime: .working, lifecycle: .working, mayHaveUnsentInput: false,
                                                   fieldVisiblyEmpty: true), .busy("working"))
    }

    func testFieldVisiblyEmptyOnlyForReadableClaudeField() {
        let empty = ControllerPromptField(rows: 1, cursorRow: 0, cursorAtStart: true, isEmpty: true)
        let text = ControllerPromptField(rows: 1, cursorRow: 0, cursorAtStart: false, isEmpty: false)
        XCTAssertTrue(PromptSubmitCheck.fieldVisiblyEmpty(field: empty, profile: .claudeCodeChat))
        XCTAssertFalse(PromptSubmitCheck.fieldVisiblyEmpty(field: text, profile: .claudeCodeChat))
        XCTAssertFalse(PromptSubmitCheck.fieldVisiblyEmpty(field: nil, profile: .claudeCodeChat), "nicht ablesbar: Schätzung gilt")
        XCTAssertFalse(PromptSubmitCheck.fieldVisiblyEmpty(field: empty, profile: .plainShell))
    }

    /// Unterer Rand eines ruhenden Chats mit Hintergrund-Befehl, abgelesen an
    /// Claude Code 2.1.325 (15.11.2026): Name in der oberen Linie, leeres Feld,
    /// darunter die Statuszeile mit „· 1 shell“. Das Feld gilt als leer.
    func testEmptyFieldAboveShellStatusLineReadsEmpty() {
        let screen = ControllerScreenReading.read(lines: [
            .plain("  ⎿  Running…"),
            .plain(""),
            .plain(String(repeating: "─", count: 50) + " wm8-105-nik-7e0e6690 ─"),
            .dimmed("❯ "),
            .plain(String(repeating: "─", count: 73)),
            .plain("  whisperm8 (main) | 32% 275k/1000k | [Opus 5.5] ⇄PowerUser | high | 3…"),
            .plain("  ⏵⏵ bypass permissions on · 1 shell · Tasks 1 aktiv · 3 offen"),
        ], cursor: (row: 3, col: 2), detectViews: true)
        XCTAssertEqual(screen.promptField?.isEmpty, true)
        XCTAssertTrue(PromptSubmitCheck.fieldVisiblyEmpty(field: screen.promptField, profile: .claudeCodeChat))
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
