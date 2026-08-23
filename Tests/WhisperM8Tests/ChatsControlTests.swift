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
        XCTAssertFalse(items[0].stopped, "ohne stop-Feld gilt: nichts wurde beendet")
    }

    func testItemsParseStoppedFlag() {
        let result = ChatsControlJSON.object([
            "ok": true, "closedCount": 1, "stoppedCount": 1,
            "results": [["id": "A1", "outcome": "closed", "stopped": true, "ptyRunning": false]],
        ])
        XCTAssertTrue(ChatsCloseSupport.items(from: result)[0].stopped)
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

    func testStoppedLineSaysAgentEndedAndHistorySurvives() {
        var stopped = item("closed", pinned: true)
        stopped.stopped = true
        let line = ChatsCloseSupport.humanLine(for: stopped, fallbackLabel: nil)
        XCTAssertTrue(line.contains("Agent gestoppt"))
        XCTAssertTrue(line.contains("Verlauf bleibt"), "Stop ist kein Archivieren und kein Löschen")
        XCTAssertTrue(line.contains("resume möglich"))
        XCTAssertTrue(line.contains("Pin bleibt"))
        XCTAssertFalse(line.contains("läuft weiter"), "nach dem Stop läuft nichts mehr")
    }

    func testFailedBackgroundStopIsReportedAsWarningNotSuccess() {
        // Hintergrund-Agenten leben im Supervisor-Daemon: das PTY zu killen
        // trennt nur die Anzeige. Schlägt `claude stop` fehl, läuft der Agent
        // weiter — eine Erfolgsmeldung wäre hier eine Falschaussage.
        var failed = item("closed")
        failed.stopFailed = true
        let line = ChatsCloseSupport.humanLine(for: failed, fallbackLabel: nil)
        XCTAssertTrue(line.contains("läuft WEITER"))
        XCTAssertFalse(line.contains("Agent gestoppt"))
        XCTAssertTrue(line.hasPrefix("⚠︎"))
    }

    func testStoppedWithoutOpenTabIsReportedAsStopNotAsNoop() {
        // Randfall: kein Tab offen, aber der Prozess lief im Hintergrund —
        // ohne diese Zeile meldete die CLI „kein offener Tab" und verschwiege
        // die eigentliche Wirkung.
        var stopped = item("alreadyClosed")
        stopped.stopped = true
        let line = ChatsCloseSupport.humanLine(for: stopped, fallbackLabel: nil)
        XCTAssertTrue(line.contains("Agent gestoppt"))
        XCTAssertTrue(line.contains("kein offener Tab"))
    }
}

final class ChatsWorkspaceMembershipSupportTests: XCTestCase {
    private func line(
        _ outcome: String, slot: Int? = nil, fromSlot: Int? = nil,
        grewTo: Int? = nil, keptSlot: Bool = false
    ) -> String {
        ChatsWorkspaceMembershipSupport.humanLine(
            name: "Recherche", outcome: outcome, slot: slot,
            fromSlot: fromSlot, grewTo: grewTo, keptSlot: keptSlot)
    }

    func testAddedNamesSlotAndGrowth() {
        let text = line("added", slot: 4, grewTo: 4)
        XCTAssertTrue(text.contains("aufgenommen"))
        XCTAssertTrue(text.contains("Slot 4"))
        XCTAssertTrue(text.contains("Grid auf 4 erweitert"))
    }

    func testMovedIsDistinguishableFromAdded() {
        // Kritisch für Agenten-Vertrauen: Ein Move darf nicht wie eine
        // Neuaufnahme klingen — vorher meldete die CLI beides als
        // „aufgenommen".
        let text = line("moved", slot: 4, fromSlot: 1)
        XCTAssertTrue(text.contains("verschoben"))
        XCTAssertTrue(text.contains("Slot 4"))
        XCTAssertTrue(text.contains("vorher Slot 1"))
        XCTAssertFalse(text.contains("aufgenommen"))
    }

    func testReplacedSaysDisplacedChatSurvivesAsTab() {
        let text = line("replaced", slot: 2)
        XCTAssertTrue(text.contains("ersetzt"))
        XCTAssertTrue(text.contains("bleibt Tab"))
    }

    func testRemovedWithKeptSlotNamesTheHole() {
        XCTAssertTrue(line("removed", keptSlot: true).contains("Slot bleibt leer"))
        XCTAssertFalse(line("removed").contains("Slot bleibt leer"))
    }

    func testAlreadyMemberShowsCurrentSlot() {
        let text = line("alreadyMember", slot: 2)
        XCTAssertTrue(text.contains("schon Mitglied"))
        XCTAssertTrue(text.contains("Slot 2"))
    }
}

final class ChatsWorkspaceOpenSupportTests: XCTestCase {
    private func line(_ outcome: String, slot: Int? = nil, occupied: Bool? = nil,
                      title: String? = nil) -> String {
        ChatsWorkspaceOpenSupport.humanLine(
            name: "Recherche", outcome: outcome, slot: slot,
            slotOccupied: occupied, focusedTitle: title)
    }

    func testActivatedAndAlreadyVisibleAreDistinguishable() {
        XCTAssertTrue(line("activated").contains("geöffnet"))
        XCTAssertTrue(line("alreadyVisible").contains("war schon sichtbar"))
    }

    func testForeignWindowSaysItOnlyFocused() {
        // Kritisch fürs Vertrauen: hier wurde NICHTS umgehängt — die Ausgabe
        // darf nicht wie eine Aktivierung im eigenen Fenster klingen.
        let text = line("focusedOwnerWindow")
        XCTAssertTrue(text.contains("besitzenden Fenster"))
        XCTAssertTrue(text.contains("nach vorn"))
    }

    func testEmptySlotIsReportedButNotAsFailure() {
        let text = line("activated", slot: 3, occupied: false)
        XCTAssertTrue(text.contains("Slot 3 ist leer"))
        XCTAssertTrue(text.hasPrefix("✓"), "leerer Slot bleibt ein Erfolg")
    }

    func testOccupiedSlotNamesTheFocusedChat() {
        let text = line("activated", slot: 2, occupied: true, title: "whisperm8/CLI")
        XCTAssertTrue(text.contains("Slot 2 fokussiert: whisperm8/CLI"))
    }

    func testOccupiedSlotWithoutTitleStillReportsFocus() {
        XCTAssertTrue(line("activated", slot: 1, occupied: true).contains("Slot 1 fokussiert"))
    }

    func testWithoutSlotNoSlotSuffix() {
        XCTAssertFalse(line("activated").contains("Slot"))
    }
}

final class ChatsCloseStopGuardTests: XCTestCase {
    private let idle = UUID()
    private let working = UUID()
    private let alsoWorking = UUID()

    private func blocking(_ targets: [UUID], force: Bool = false) -> [String] {
        ChatsCloseStopGuard.blockingTargets(
            targetIDs: targets,
            force: force,
            isWorking: { $0 == working || $0 == alsoWorking },
            label: { id in
                if id == working { return "whisperm8/Plan" }
                if id == alsoWorking { return "akquise/Mails" }
                return "whisperm8/Idle"
            })
    }

    func testIdleTargetsAreNeverBlocked() {
        XCTAssertTrue(blocking([idle]).isEmpty)
        XCTAssertTrue(blocking([]).isEmpty)
    }

    func testSingleWorkingTargetBlocksTheWholeBatch() {
        // Alles-oder-nichts: sonst wären die idle-Tabs schon zu, wenn der
        // Aufrufer den Konflikt sieht.
        XCTAssertEqual(blocking([idle, working]), ["whisperm8/Plan"])
    }

    func testAllWorkingTargetsAreNamed() {
        XCTAssertEqual(blocking([working, idle, alsoWorking]),
                       ["whisperm8/Plan", "akquise/Mails"])
    }

    func testForceLiftsTheGuard() {
        XCTAssertTrue(blocking([working, alsoWorking], force: true).isEmpty)
    }

    func testUnlabeledTargetFallsBackToItsID() {
        let unknown = UUID()
        let names = ChatsCloseStopGuard.blockingTargets(
            targetIDs: [unknown], force: false, isWorking: { _ in true }, label: { _ in nil })
        XCTAssertEqual(names, [unknown.uuidString])
    }

    func testConflictMessageNamesTargetsAndAllThreeWaysOut() {
        let message = ChatsCloseStopGuard.conflictMessage(blocking: ["whisperm8/Plan"])
        XCTAssertTrue(message.contains("whisperm8/Plan"))
        XCTAssertTrue(message.contains("kein Tab wurde geschlossen"))
        XCTAssertTrue(message.contains("interrupt"))
        XCTAssertTrue(message.contains("--stop --force"))
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

    func testCloseRejectsBadModesBeforeTouchingState() async {
        let handler = AgentControlRequestHandler()

        let badMode = await handler.handle(ChatsControlRequest(
            requestID: "m1", actor: ChatsControlActor(), method: "session.close",
            params: .object(["targetSessionIDs": [UUID().uuidString], "mode": "banane"])))
        XCTAssertEqual(badMode.error?.code, "invalid")

        let twoAnchors = await handler.handle(ChatsControlRequest(
            requestID: "m2", actor: ChatsControlActor(), method: "session.close",
            params: .object(["targetSessionIDs": [UUID().uuidString, UUID().uuidString],
                             "mode": "others"])))
        XCTAssertEqual(twoAnchors.error?.code, "invalid",
                       "others/right verlangen genau EINEN Anker")
    }

    func testPinAndMoveValidateParams() async {
        let handler = AgentControlRequestHandler()

        let pinWithoutFlag = await handler.handle(ChatsControlRequest(
            requestID: "p1", actor: ChatsControlActor(), method: "session.pin",
            params: .object(["targetSessionIDs": [UUID().uuidString]])))
        XCTAssertEqual(pinWithoutFlag.error?.code, "invalid", "pinned true|false ist Pflicht")

        let moveWithoutWindow = await handler.handle(ChatsControlRequest(
            requestID: "p2", actor: ChatsControlActor(), method: "session.move",
            params: .object(["targetSessionID": UUID().uuidString])))
        XCTAssertEqual(moveWithoutWindow.error?.code, "invalid")

        let membershipWithoutWorkspace = await handler.handle(ChatsControlRequest(
            requestID: "p3", actor: ChatsControlActor(), method: "gridWorkspace.add",
            params: .object(["targetSessionID": UUID().uuidString])))
        XCTAssertEqual(membershipWithoutWorkspace.error?.code, "invalid")
    }

    func testUnarchiveValidatesParamsBeforeTouchingState() async {
        let handler = AgentControlRequestHandler()

        let missing = await handler.handle(ChatsControlRequest(
            requestID: "u1", actor: ChatsControlActor(), method: "workspace.unarchive"))
        XCTAssertEqual(missing.error?.code, "invalid")

        let both = await handler.handle(ChatsControlRequest(
            requestID: "u2", actor: ChatsControlActor(), method: "workspace.unarchive",
            params: .object(["targetSessionID": UUID().uuidString,
                             "resume": true, "open": true])))
        XCTAssertEqual(both.error?.code, "invalid", "resume und open schliessen sich aus")
    }
}

// MARK: - Fenster- und Workspace-Referenzen (move / workspace add|remove)

@MainActor
final class ChatsWindowAndWorkspaceRefTests: XCTestCase {
    private func makeStore() -> AgentWindowStore {
        let dir = FileManager.default.temporaryDirectory
        let persistence = AgentSessionStore(
            fileURL: dir.appendingPathComponent("wm8-ref-ws-\(UUID().uuidString).json"),
            uiStateFileURL: dir.appendingPathComponent("wm8-ref-ui-\(UUID().uuidString).json"))
        return AgentWindowStore(persistence: persistence)
    }

    func testResolveWindowRefPrimaryPrefixAndMisses() {
        let store = makeStore()
        let primary = store.primaryWindowID
        let a = UUID(); let b = UUID()
        store.openTab(a, in: primary); store.openTab(b, in: primary)
        let secondary = store.detachToNewWindow(b, from: primary)

        XCTAssertEqual(AgentControlRequestHandler.resolveWindowRef("primary", store: store), primary)
        XCTAssertEqual(AgentControlRequestHandler.resolveWindowRef("PRIMARY", store: store), primary)
        XCTAssertEqual(AgentControlRequestHandler.resolveWindowRef(secondary.uuidString, store: store), secondary)
        let prefix = String(secondary.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        XCTAssertEqual(AgentControlRequestHandler.resolveWindowRef(prefix, store: store), secondary)
        XCTAssertNil(AgentControlRequestHandler.resolveWindowRef("abc", store: store), "Praefix < 8 Zeichen")
        XCTAssertNil(AgentControlRequestHandler.resolveWindowRef(UUID().uuidString, store: store), "fremde ID")
    }

    func testResolveGridWorkspaceRefExactBeatsSubstring() {
        let base = AgentGridWorkspace(name: "Workspace", colorHex: AgentGridWorkspace.defaultColorHex,
                                      slots: [], capacity: 2)
        let second = AgentGridWorkspace(name: "Workspace 2", colorHex: AgentGridWorkspace.defaultColorHex,
                                        slots: [], capacity: 2)
        let all = [base, second]

        if case .success(let match) = AgentControlRequestHandler.resolveGridWorkspaceRef("Workspace", all: all) {
            XCTAssertEqual(match.id, base.id, "exakter Name gewinnt vor Substring")
        } else {
            XCTFail("exakter Match darf nicht mehrdeutig sein")
        }
        if case .success(let match) = AgentControlRequestHandler.resolveGridWorkspaceRef(base.id.uuidString, all: all) {
            XCTAssertEqual(match.id, base.id)
        } else {
            XCTFail("ID-Match fehlgeschlagen")
        }
        if case .failure = AgentControlRequestHandler.resolveGridWorkspaceRef("space", all: all) {
            // mehrdeutiger Substring → Fehler, nie raten
        } else {
            XCTFail("mehrdeutiger Substring muss scheitern")
        }
        if case .failure = AgentControlRequestHandler.resolveGridWorkspaceRef("gibtsnicht", all: all) {
            // unbekannt → Fehler
        } else {
            XCTFail("unbekannter Name muss scheitern")
        }
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

// MARK: - Lock-Retry beim App-Neustart

/// Vorfall 2026-07-24: Ein `make dev`-Neustart traf den `flock` des eben
/// beendeten Vorgängers. Der Server gab beim ERSTEN Konflikt endgültig auf —
/// die CLI-Steuerung blieb für die gesamte App-Laufzeit tot, ohne zweiten
/// Versuch. Vorfall 2026-08-23: Der Vorgänger-Shutdown überdauerte auch das
/// endliche Eskalationsfenster (~8 s) — wieder Totalausfall für Stunden,
/// obwohl der Lock Sekunden nach dem Aufgeben frei war. Seitdem gibt es KEIN
/// endgültiges Aufgeben mehr: nach der Eskalation läuft ein unbegrenzter
/// Dauer-Retry im gedeckelten Takt. Diese Tests pinnen die Retry-Politik und
/// die Kernannahme dahinter.
final class AgentControlServerLockRetryTests: XCTestCase {
    func testRetryDelaysCoverATypicalRestartWindow() {
        let delays = AgentControlServer.lockRetryDelays

        XCTAssertFalse(delays.isEmpty, "ohne Retry wäre der Vorfall wieder möglich")
        XCTAssertEqual(delays, delays.sorted(), "Backoff muss monoton wachsen")
        XCTAssertTrue(delays.allSatisfy { $0 > 0 })
        // Eskalationsfenster großzügig über dem beobachteten Konflikt (< 1 s);
        // dass es endlich ist, ist ok — danach übernimmt der Dauer-Retry.
        XCTAssertGreaterThanOrEqual(delays.reduce(0, +), 5)
        XCTAssertLessThanOrEqual(delays.reduce(0, +), 30)
    }

    /// Der Dauer-Retry ist die Lehre aus 2026-08-23: schnell genug, dass die
    /// CLI-Steuerung nach einem zähen Neustart-Überlapp binnen Sekunden
    /// nachzieht — und langsam genug, dass ein echter Doppelstart weder CPU
    /// noch Log flutet (notices zusätzlich auf jeden N-ten Versuch gedrosselt).
    func testEndlessTailRetryIsCappedAndQuiet() {
        XCTAssertGreaterThanOrEqual(AgentControlServer.lockRetryTailDelay, 5)
        XCTAssertLessThanOrEqual(AgentControlServer.lockRetryTailDelay, 60)
        XCTAssertGreaterThanOrEqual(
            AgentControlServer.lockRetryTailDelay * TimeInterval(AgentControlServer.lockRetryTailLogEvery),
            60,
            "gedrosselte notices: höchstens grob eine pro Minute"
        )
    }

    /// Die Annahme des Fixes: Ein von einem anderen Deskriptor gehaltener
    /// `flock` lässt `LOCK_EX | LOCK_NB` scheitern und gelingt, sobald der
    /// Vorgänger losgelassen hat. Genau dieses Zeitfenster überbrückt der Retry.
    func testNonBlockingFlockFailsWhileHeldAndSucceedsAfterRelease() throws {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctrl-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: lockURL) }

        let holderFD = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(holderFD, 0)
        XCTAssertEqual(flock(holderFD, LOCK_EX | LOCK_NB), 0)

        let contenderFD = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(contenderFD, 0)
        defer { close(contenderFD) }
        XCTAssertNotEqual(
            flock(contenderFD, LOCK_EX | LOCK_NB), 0,
            "solange der Vorgänger hält, muss der Start fail-closed bleiben"
        )

        // Vorgänger endgültig weg (entspricht dem abgeräumten alten Prozess).
        close(holderFD)

        XCTAssertEqual(
            flock(contenderFD, LOCK_EX | LOCK_NB), 0,
            "nach Freigabe muss ein späterer Versuch durchkommen"
        )
        flock(contenderFD, LOCK_UN)
    }
}
