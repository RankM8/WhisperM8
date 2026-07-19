import XCTest
@testable import WhisperM8

// MARK: - NDJSON-Codec + Protokoll-Roundtrip

final class ChatsControlCodecTests: XCTestCase {
    func testRequestRoundtrip() throws {
        let request = ChatsControlRequest(
            requestID: "abc",
            actor: ChatsControlActor(sessionID: UUID().uuidString, token: "tok"),
            method: "session.send",
            params: .object([
                "targetSessionID": "6F2B41A0-0000-4000-8000-000000000001",
                "prompt": "mehrzeilig\nzweite zeile",
                "submit": true,
            ]))
        let line = try ChatsControlCodec.encodeLine(request)
        // Genau ein abschließendes 0x0A, keine rohen Newlines im JSON-Body.
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertEqual(line.filter { $0 == 0x0A }.count, 1, "eingebettete Newlines müssen JSON-escaped sein")
        let decoded = try ChatsControlCodec.decode(ChatsControlRequest.self, from: line.dropLast())
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.params["prompt"]?.stringValue, "mehrzeilig\nzweite zeile")
    }

    func testResponseSuccessAndFailureRoundtrip() throws {
        let success = ChatsControlResponse.success(requestID: "x", result: .object(["ack": "delivered"]))
        let successLine = try ChatsControlCodec.encodeLine(success)
        let decodedSuccess = try ChatsControlCodec.decode(ChatsControlResponse.self, from: successLine.dropLast())
        XCTAssertTrue(decodedSuccess.ok)
        XCTAssertEqual(decodedSuccess.result?["ack"]?.stringValue, "delivered")

        let failure = ChatsControlResponse.failure(requestID: "x", code: .conflict, message: "working")
        let failureLine = try ChatsControlCodec.encodeLine(failure)
        let decodedFailure = try ChatsControlCodec.decode(ChatsControlResponse.self, from: failureLine.dropLast())
        XCTAssertFalse(decodedFailure.ok)
        XCTAssertEqual(decodedFailure.error?.code, "conflict")
    }

    func testErrorCodeExitMapping() {
        XCTAssertEqual(ChatsControlErrorCode.notFound.exitCode, ChatsCLIExit.notFound)
        XCTAssertEqual(ChatsControlErrorCode.conflict.exitCode, ChatsCLIExit.conflict)
        XCTAssertEqual(ChatsControlErrorCode.selfSend.exitCode, ChatsCLIExit.conflict)
        XCTAssertEqual(ChatsControlErrorCode.noPty.exitCode, ChatsCLIExit.conflict)
        XCTAssertEqual(ChatsControlErrorCode.invalid.exitCode, ChatsCLIExit.usage)
    }

    func testJSONValueAccessors() {
        let json = ChatsControlJSON.object([
            "s": .string("hi"), "n": .number(42), "b": .bool(true),
            "arr": .array([.string("a"), .string("b")]),
        ])
        XCTAssertEqual(json["s"]?.stringValue, "hi")
        XCTAssertEqual(json["b"]?.boolValue, true)
        XCTAssertEqual(json["arr"]?.arrayValue?.count, 2)
        XCTAssertNil(json["missing"])
    }
}

// MARK: - sun_path-Limit + Pfad-Wahl

final class ChatsControlProtocolTests: XCTestCase {
    func testSocketPathFitsRespects104ByteLimit() {
        let short = URL(fileURLWithPath: "/private/tmp/whisperm8-501/control.sock")
        XCTAssertTrue(ChatsControlProtocol.socketPathFits(short))

        let long = URL(fileURLWithPath: "/" + String(repeating: "a", count: 200) + "/control.sock")
        XCTAssertFalse(ChatsControlProtocol.socketPathFits(long))
    }

    func testFallbackPathIsShortEnough() {
        XCTAssertTrue(ChatsControlProtocol.socketPathFits(ChatsControlProtocol.fallbackSocketURL()))
    }
}

// MARK: - Token-Registry

final class AgentSessionTokenRegistryTests: XCTestCase {
    func testIssueAndVerify() {
        let registry = AgentSessionTokenRegistry.shared
        let id = UUID()
        let token = registry.issueToken(for: id)
        XCTAssertTrue(registry.verify(sessionID: id, token: token))
        XCTAssertFalse(registry.verify(sessionID: id, token: "falsch"))
        XCTAssertFalse(registry.verify(sessionID: id, token: nil))
        XCTAssertFalse(registry.verify(sessionID: UUID(), token: token))
        registry.revoke(sessionID: id)
        XCTAssertFalse(registry.verify(sessionID: id, token: token))
    }

    func testReissueReplacesToken() {
        let registry = AgentSessionTokenRegistry.shared
        let id = UUID()
        let first = registry.issueToken(for: id)
        let second = registry.issueToken(for: id)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(registry.verify(sessionID: id, token: first))
        XCTAssertTrue(registry.verify(sessionID: id, token: second))
        registry.revoke(sessionID: id)
    }
}

// MARK: - Marker-Zeile (Kennzeichnung + Ein-Hop)

final class ChatsMarkerTests: XCTestCase {
    func testMarkedPromptHasMarkerLineAndPreservesBody() {
        let marked = AgentControlRequestHandler.markedPrompt("Bitte Botox zuerst.", actor: "jarvis/supervisor")
        let lines = marked.components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("[via whisperm8 chats · von jarvis/supervisor · "))
        XCTAssertTrue(lines[0].hasSuffix("]"))
        XCTAssertEqual(lines.dropFirst().joined(separator: "\n"), "Bitte Botox zuerst.")
    }

    func testMarkedPromptPreservesMultilineBody() {
        let marked = AgentControlRequestHandler.markedPrompt("Zeile 1\nZeile 2", actor: "extern")
        let body = marked.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
        XCTAssertEqual(body, "Zeile 1\nZeile 2")
    }
}

// MARK: - Audit-Log

final class ChatsAuditLogTests: XCTestCase {
    private var tempURL: URL!

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chats-audit-\(UUID().uuidString).jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("1"))
    }

    func testAppendAndRecent() {
        let log = ChatsAuditLog(fileURL: tempURL)
        for i in 0..<5 {
            log.append(ChatsAuditEntry(at: Date(), actor: "a\(i)", verified: true, method: "send",
                                       target: "proj/session", outcome: "ok", promptChars: 10, promptHead: "hi"))
        }
        let recent = log.recent(limit: 3)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent.last?.actor, "a4")
    }

    func testTargetFilter() {
        let log = ChatsAuditLog(fileURL: tempURL)
        log.append(ChatsAuditEntry(at: Date(), actor: "x", verified: true, method: "send", target: "a/b", outcome: "ok", promptChars: nil, promptHead: nil))
        log.append(ChatsAuditEntry(at: Date(), actor: "x", verified: true, method: "send", target: "c/d", outcome: "ok", promptChars: nil, promptHead: nil))
        XCTAssertEqual(log.recent(limit: 10, targetFilter: "a/b").count, 1)
    }

    func testRotationAtMaxBytes() {
        let log = ChatsAuditLog(fileURL: tempURL, maxBytes: 200)
        for i in 0..<20 {
            log.append(ChatsAuditEntry(at: Date(), actor: "actor-\(i)", verified: true, method: "send",
                                       target: "project/session-name", outcome: "ok", promptChars: 100,
                                       promptHead: "ein etwas längerer Prompt-Kopf zum Auffüllen"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.appendingPathExtension("1").path),
                      "Rotation muss ein .1-Sidecar erzeugt haben")
    }

    func testPromptHeadTruncates() {
        let long = String(repeating: "x", count: 200)
        XCTAssertLessThanOrEqual(ChatsAuditLog.promptHead(long).count, 80)
        XCTAssertTrue(ChatsAuditLog.promptHead(long).hasSuffix("…"))
        XCTAssertEqual(ChatsAuditLog.promptHead("kurz"), "kurz")
    }
}

// MARK: - Idempotenz (atomare In-flight-Reservierung, GPT-Review G)

final class ChatsIdempotencyTests: XCTestCase {
    private func isFresh(_ r: AgentControlRequestHandler.IdempotencyReservation) -> Bool {
        if case .fresh = r { return true }
        return false
    }

    func testConcurrentDuplicatesReserveExactlyOnce() async {
        let handler = AgentControlRequestHandler()
        let requestID = UUID().uuidString
        // 20 nebenläufige Reservierungen derselben ID — genau EINE darf „frisch"
        // zurückbekommen, der Rest sieht inFlight.
        let freshCount = await withTaskGroup(of: Bool.self) { group -> Int in
            for _ in 0..<20 {
                group.addTask { [self] in isFresh(handler.reserveIdempotencyForTest(requestID)) }
            }
            var count = 0
            for await fresh in group where fresh { count += 1 }
            return count
        }
        XCTAssertEqual(freshCount, 1, "genau eine Reservierung darf frisch sein")
    }

    func testReleaseAllowsRetry() {
        let handler = AgentControlRequestHandler()
        let id = UUID().uuidString
        XCTAssertTrue(isFresh(handler.reserveIdempotencyForTest(id)))       // frisch
        guard case .stillInFlight = handler.reserveIdempotencyForTest(id) else {
            return XCTFail("zweite Reservierung muss stillInFlight sein")
        }
        handler.releaseIdempotencyForTest(id)                               // Guard-Fehler → freigeben
        XCTAssertTrue(isFresh(handler.reserveIdempotencyForTest(id)))       // Retry wieder frisch
    }

    func testCompleteMarksDuplicate() {
        let handler = AgentControlRequestHandler()
        let id = UUID().uuidString
        XCTAssertTrue(isFresh(handler.reserveIdempotencyForTest(id)))
        handler.completeIdempotencyForTest(id)
        guard case .completedEarlier = handler.reserveIdempotencyForTest(id) else {
            return XCTFail("abgeschlossene ID muss completedEarlier melden")
        }
    }
}

// MARK: - session.close (Batch-Contract: Outcomes, Exit-Codes, Validierung)

final class ChatsCloseSupportTests: XCTestCase {
    private func item(_ outcome: String, ptyRunning: Bool = false,
                      status: String? = nil, pinned: Bool = false) -> ChatsCloseResultItem {
        ChatsCloseResultItem(id: UUID().uuidString, title: "T", project: "P", outcome: outcome,
                             ptyRunning: ptyRunning, runtimeStatus: status, isPinned: pinned)
    }

    func testItemsParseFromServerResult() {
        let result = ChatsControlJSON.object([
            "ok": true,
            "closedCount": 1,
            "results": [
                ["id": "A1", "outcome": "closed", "title": "Chat", "project": "whisperm8",
                 "ptyRunning": true, "runtimeStatus": "working", "isPinned": true],
                ["id": "B2", "outcome": "notFound", "ptyRunning": false, "isPinned": false],
            ],
        ])
        let items = ChatsCloseSupport.items(from: result)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0], ChatsCloseResultItem(
            id: "A1", title: "Chat", project: "whisperm8", outcome: "closed",
            ptyRunning: true, runtimeStatus: "working", isPinned: true))
        XCTAssertEqual(items[1].outcome, "notFound")
        XCTAssertNil(items[1].title)
    }

    func testExitCodeIsOkUnlessAnyNotFound() {
        XCTAssertEqual(ChatsCloseSupport.exitCode(for: [item("closed"), item("alreadyClosed")]),
                       ChatsCLIExit.ok, "alreadyClosed ist idempotenter Erfolg")
        XCTAssertEqual(ChatsCloseSupport.exitCode(for: [item("closed"), item("notFound")]),
                       ChatsCLIExit.notFound)
        XCTAssertEqual(ChatsCloseSupport.exitCode(for: []), ChatsCLIExit.ok)
    }

    func testHumanLinesReflectRuntimeAndPin() {
        let running = ChatsCloseSupport.humanLine(
            for: item("closed", ptyRunning: true, status: "working", pinned: true), fallbackLabel: nil)
        XCTAssertTrue(running.contains("läuft weiter"), "Close bei laufender Session bleibt nur UI")
        XCTAssertTrue(running.contains("working"))
        XCTAssertTrue(running.contains("Pin bleibt"))

        let idle = ChatsCloseSupport.humanLine(for: item("closed"), fallbackLabel: nil)
        XCTAssertTrue(idle.contains("Session bleibt erhalten"))

        let missing = ChatsCloseSupport.humanLine(
            for: ChatsCloseResultItem(id: "X", title: nil, project: nil, outcome: "notFound",
                                      ptyRunning: false, runtimeStatus: nil, isPinned: false),
            fallbackLabel: "whisperm8/alt")
        XCTAssertTrue(missing.contains("whisperm8/alt"), "notFound nutzt das CLI-Label")
    }
}

final class ChatsCloseHandlerValidationTests: XCTestCase {
    /// Der Parameter-Guard läuft VOR jedem App-State-Zugriff — kaputte
    /// Requests werden abgewiesen, ohne dass irgendein Tab schließt.
    func testCloseRejectsMissingOrMalformedTargetIDs() async {
        let handler = AgentControlRequestHandler()

        let missing = await handler.handle(ChatsControlRequest(
            requestID: "c1", actor: ChatsControlActor(), method: "session.close"))
        XCTAssertFalse(missing.ok)
        XCTAssertEqual(missing.error?.code, "invalid")

        let malformed = await handler.handle(ChatsControlRequest(
            requestID: "c2", actor: ChatsControlActor(), method: "session.close",
            params: .object(["targetSessionIDs": [UUID().uuidString, "keine-uuid"]])))
        XCTAssertFalse(malformed.ok)
        XCTAssertEqual(malformed.error?.code, "invalid",
                       "eine einzige kaputte ID lehnt den ganzen Batch ab (alles-oder-nichts)")

        let empty = await handler.handle(ChatsControlRequest(
            requestID: "c3", actor: ChatsControlActor(), method: "session.close",
            params: .object(["targetSessionIDs": [Any]()])))
        XCTAssertFalse(empty.ok)
        XCTAssertEqual(empty.error?.code, "invalid")
    }
}

// MARK: - In-Process-Socket-Roundtrip (Server + Client über Temp-Socket)

final class AgentControlServerRoundtripTests: XCTestCase {
    /// Fake-Handler, der die Requests einfach spiegelt — testet die reine
    /// Socket-Mechanik (bind, accept, getpeereid, NDJSON) ohne App-Logik.
    private struct EchoHandler: AgentControlRequestHandling {
        func handle(_ request: ChatsControlRequest) async -> ChatsControlResponse {
            if request.method == "boom" {
                return .failure(requestID: request.requestID, code: .conflict, message: "kaputt")
            }
            return .success(requestID: request.requestID, result: .object([
                "echoedMethod": request.method,
                "actorSession": request.actor.sessionID ?? "none",
            ]))
        }
    }

    func testServerClientRoundtripOverTempSocket() throws {
        // Direkter Low-Level-Roundtrip: Server-Bind → Client-Connect →
        // Request → Response. Nutzt die echten Codec- und Socket-Pfade.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctrl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let socketURL = tempDir.appendingPathComponent("t.sock")

        let handler = EchoHandler()
        let server = try TestControlSocket.listen(at: socketURL, handler: handler)
        defer { server.stop() }

        // Client-Request bauen und low-level senden.
        let request = ChatsControlRequest(
            requestID: "r1",
            actor: ChatsControlActor(sessionID: UUID().uuidString, token: "t"),
            method: "ping")
        let response = try TestControlSocket.sendRequest(request, to: socketURL)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["echoedMethod"]?.stringValue, "ping")

        // Fehlerpfad.
        let boomRequest = ChatsControlRequest(requestID: "r2", actor: ChatsControlActor(), method: "boom")
        let boomResponse = try TestControlSocket.sendRequest(boomRequest, to: socketURL)
        XCTAssertFalse(boomResponse.ok)
        XCTAssertEqual(boomResponse.error?.code, "conflict")
    }
}
