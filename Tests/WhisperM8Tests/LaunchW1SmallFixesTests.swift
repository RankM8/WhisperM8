import XCTest
@testable import WhisperM8

/// Kleine Sicherheits- und Datenschutz-Fixes der Welle W1.
final class LaunchW1SmallFixesTests: XCTestCase {
    // MARK: LR-PJ-004

    func testBoardTextDropsControlSequences() {
        let clean = JarvisBoardText.sanitize("Titel\u{1B}[31m rot\u{9B}x\u{07}\nZeile 2")
        XCTAssertFalse(clean.contains("\u{1B}"))
        XCTAssertFalse(clean.contains("\u{9B}"))
        XCTAssertFalse(clean.contains("\u{07}"))
        XCTAssertFalse(clean.contains("\n"))
        XCTAssertTrue(clean.hasPrefix("Titel"))
    }

    // MARK: LR-CLI-011

    func testQueueDeliveryAuditKeepsEnqueueVerification() {
        let unverified = QueuedPrompt(sessionID: UUID(), prompt: "mach\nweiter", enqueuedAt: Date(),
                                      enqueuedBy: "unverified", enqueuedVerified: false)
        let entry = AgentPromptQueueDelivery.deliveryAuditEntry(for: unverified, target: "x", at: Date())
        XCTAssertFalse(entry.verified)
        XCTAssertEqual(entry.promptHead, "mach weiter")

        let verified = QueuedPrompt(sessionID: UUID(), prompt: "ok", enqueuedAt: Date(),
                                    enqueuedBy: "p/chat", enqueuedVerified: true)
        XCTAssertTrue(AgentPromptQueueDelivery.deliveryAuditEntry(for: verified, target: "x", at: Date()).verified)
    }

    func testQueueVerificationSurvivesPersistenceAndOldFilesDecodeUnverified() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("queue-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentPromptQueueStore(fileURL: url)
        let target = UUID()
        store.enqueue(sessionID: target, prompt: "a", by: "p/chat", verified: true)
        XCTAssertEqual(AgentPromptQueueStore(fileURL: url).all().first?.enqueuedVerified, true)

        let legacy = #"{"sessionID":"\#(target.uuidString)","prompt":"b","enqueuedAt":0,"enqueuedBy":"extern"}"#
        let decoded = try JSONDecoder().decode(QueuedPrompt.self, from: Data(legacy.utf8))
        XCTAssertFalse(decoded.enqueuedVerified)
    }

    // MARK: LR-AU-032

    func testExtraArgumentsPlaceholderIsHarmlessAndDangerousFlagsWarn() {
        XCTAssertFalse(AgentCLIArgumentsPreview.placeholder(binary: "claude").contains("dangerously"))
        XCTAssertFalse(AgentCLIArgumentsPreview.placeholder(binary: "codex").contains("dangerously"))
        XCTAssertEqual(AgentCLIArgumentsPreview.dangerousArguments(in: "--dangerously-skip-permissions"),
                       ["--dangerously-skip-permissions"])
        XCTAssertEqual(AgentCLIArgumentsPreview.dangerousArguments(in: "--permission-mode bypassPermissions"),
                       ["--permission-mode", "bypassPermissions"])
        XCTAssertEqual(AgentCLIArgumentsPreview.dangerousArguments(in: "--yolo"), ["--yolo"])
        XCTAssertTrue(AgentCLIArgumentsPreview.dangerousArguments(in: "--verbose --model opus").isEmpty)
    }

    // MARK: LR-SH-008

    func testBrokenTranscriptionResponseDoesNotLogContent() {
        var logged: [String] = []
        Logger.testSink = { logged.append($0) }
        defer { Logger.testSink = nil }
        XCTAssertThrowsError(try MultipartTranscriptionClient.decodeLogged(
            TranscriptionResponse.self, from: Data(#"{"text":"GEHEIMER DIKTATTEXT"#.utf8)))
        XCTAssertFalse(logged.isEmpty, "der Fehler selbst wird weiter protokolliert")
        XCTAssertFalse(logged.joined().contains("GEHEIM"))
    }

    // MARK: LR-GPT-007

    func testDisabledBackendShowsAndFetchesNoProxyAccounts() {
        let main = GPTAccountProfile(name: "main", configDir: URL(fileURLWithPath: "/tmp"), accountID: "acc")
        var listed = false
        let shown = CodexUsagePopoverTargets.displayedProfiles(
            backendEnabled: false, profilesEnabled: true,
            all: { listed = true; return [main] }, main: { main })
        XCTAssertTrue(shown.isEmpty)
        XCTAssertFalse(listed, "kein Disk-Zugriff auf Profile bei ausgeschaltetem Backend")
        XCTAssertEqual(CodexUsagePopoverTargets.displayedProfiles(
            backendEnabled: true, profilesEnabled: false, all: { [] }, main: { main }), [main])
    }

    // MARK: LR-KO-012

    func testUsageCacheOfOtherUserIsIgnored() {
        XCTAssertTrue(ClaudeAccountUsageFetcher.isOwnedByCurrentUser([.ownerAccountID: NSNumber(value: 501)], uid: 501))
        XCTAssertFalse(ClaudeAccountUsageFetcher.isOwnedByCurrentUser([.ownerAccountID: NSNumber(value: 502)], uid: 501))
        XCTAssertFalse(ClaudeAccountUsageFetcher.isOwnedByCurrentUser(nil, uid: 501))
    }
}
