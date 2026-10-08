import XCTest
@testable import WhisperM8

// MARK: - Pure Board-Logik

final class JarvisBoardLogicTests: XCTestCase {
    private let owner = UUID()
    private let chat = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testSetCreatesActiveBoardAndNewEntryDefaultsToRunning() {
        var file = JarvisBoardFile()
        let change = JarvisBoardLogic.set(&file, owner: owner, sessionID: chat,
                                          patch: JarvisBoardPatch(mission: "Opener bauen"), now: t0)
        XCTAssertTrue(change.changed)
        XCTAssertEqual(change.light, .running)
        let board = try? XCTUnwrap(file.board(owner: owner))
        XCTAssertEqual(board?.isActive, true, "wer einträgt, will das Board auch sehen")
        XCTAssertEqual(board?.entries.first?.mission, "Opener bauen")
        XCTAssertEqual(board?.entries.first?.needs, "")
        XCTAssertEqual(board?.entries.first?.updatedAt, t0)
    }

    func testSetMergesOnlyGivenFieldsAndBumpsUpdatedAtOnlyOnChange() {
        var file = JarvisBoardFile()
        _ = JarvisBoardLogic.set(&file, owner: owner, sessionID: chat,
                                 patch: JarvisBoardPatch(light: .running, mission: "M", needs: "N", next: "X"), now: t0)
        let t1 = t0.addingTimeInterval(60)
        let change = JarvisBoardLogic.set(&file, owner: owner, sessionID: chat,
                                          patch: JarvisBoardPatch(light: .needsYou), now: t1)
        XCTAssertTrue(change.changed)
        let entry = file.board(owner: owner)!.entries[0]
        XCTAssertEqual(entry.light, .needsYou)
        XCTAssertEqual([entry.mission, entry.needs, entry.next], ["M", "N", "X"], "nicht genannte Felder bleiben")
        XCTAssertEqual(entry.updatedAt, t1)

        let t2 = t1.addingTimeInterval(60)
        let same = JarvisBoardLogic.set(&file, owner: owner, sessionID: chat,
                                        patch: JarvisBoardPatch(light: .needsYou, mission: "M"), now: t2)
        XCTAssertFalse(same.changed, "identische Werte sind keine Änderung — kein Journal-Ereignis")
        XCTAssertEqual(file.board(owner: owner)!.entries[0].updatedAt, t1)
    }

    func testEmptyTextClearsField() {
        var file = JarvisBoardFile()
        _ = JarvisBoardLogic.set(&file, owner: owner, sessionID: chat, patch: JarvisBoardPatch(needs: "Freigabe"), now: t0)
        _ = JarvisBoardLogic.set(&file, owner: owner, sessionID: chat, patch: JarvisBoardPatch(needs: "  "), now: t0)
        XCTAssertEqual(file.board(owner: owner)!.entries[0].needs, "")
    }

    func testTextIsSingleLineTrimmedAndTruncated() {
        XCTAssertEqual(JarvisBoardText.sanitize("  Zeile eins\nZeile zwei\r\n\ndrei  "), "Zeile eins Zeile zwei drei")
        let long = String(repeating: "a", count: 200)
        let cut = JarvisBoardText.sanitize(long)
        XCTAssertEqual(cut.count, JarvisBoardText.maxLength)
        XCTAssertTrue(cut.hasSuffix("…"))
        let exact = String(repeating: "b", count: 160)
        XCTAssertEqual(JarvisBoardText.sanitize(exact), exact, "genau 160 Zeichen bleiben ungekürzt")
    }

    func testRemoveAndClear() {
        var file = JarvisBoardFile()
        let other = UUID()
        _ = JarvisBoardLogic.set(&file, owner: owner, sessionID: chat, patch: JarvisBoardPatch(light: .done), now: t0)
        _ = JarvisBoardLogic.set(&file, owner: owner, sessionID: other, patch: JarvisBoardPatch(), now: t0)

        let removed = JarvisBoardLogic.remove(&file, owner: owner, sessionID: chat, now: t0)
        XCTAssertTrue(removed.changed)
        XCTAssertEqual(removed.light, .done, "remove meldet die zuletzt gültige Ampel")
        XCTAssertFalse(JarvisBoardLogic.remove(&file, owner: owner, sessionID: chat, now: t0).changed)

        let cleared = JarvisBoardLogic.clear(&file, owner: owner, now: t0)
        XCTAssertEqual(cleared.removedCount, 1)
        XCTAssertEqual(file.board(owner: owner)?.entries.count, 0)
        XCTAssertEqual(file.board(owner: owner)?.isActive, true, "clear schaltet das Board nicht aus")
        XCTAssertFalse(JarvisBoardLogic.clear(&file, owner: owner, now: t0).changed)
    }

    func testActivateAndDeactivate() {
        var file = JarvisBoardFile()
        XCTAssertFalse(JarvisBoardLogic.setActive(&file, owner: owner, active: false, now: t0).changed,
                       "deactivate ohne Board ist ein No-op")
        XCTAssertTrue(file.boards.isEmpty)
        XCTAssertTrue(JarvisBoardLogic.setActive(&file, owner: owner, active: true, now: t0).changed)
        XCTAssertFalse(JarvisBoardLogic.setActive(&file, owner: owner, active: true, now: t0).changed,
                       "wiederholtes activate (Skill-Hook) erzeugt kein Ereignis")
        XCTAssertTrue(JarvisBoardLogic.setActive(&file, owner: owner, active: false, now: t0).changed)
        XCTAssertEqual(file.board(owner: owner)?.isActive, false)
    }

    func testSortingByLightThenOldestUpdatedAt() {
        let ids = (0..<5).map { _ in UUID() }
        let entries = [
            JarvisBoardEntry(sessionID: ids[0], light: .parked, updatedAt: t0),
            JarvisBoardEntry(sessionID: ids[1], light: .running, updatedAt: t0.addingTimeInterval(10)),
            JarvisBoardEntry(sessionID: ids[2], light: .done, updatedAt: t0),
            JarvisBoardEntry(sessionID: ids[3], light: .needsYou, updatedAt: t0.addingTimeInterval(5)),
            JarvisBoardEntry(sessionID: ids[4], light: .running, updatedAt: t0),
        ]
        XCTAssertEqual(JarvisBoardLogic.sorted(entries).map(\.sessionID), [ids[3], ids[2], ids[4], ids[1], ids[0]])
    }

    func testChatMayStandOnSeveralBoards() {
        var file = JarvisBoardFile()
        let secondOwner = UUID()
        _ = JarvisBoardLogic.set(&file, owner: owner, sessionID: chat, patch: JarvisBoardPatch(), now: t0)
        _ = JarvisBoardLogic.set(&file, owner: secondOwner, sessionID: chat, patch: JarvisBoardPatch(light: .parked), now: t0)
        XCTAssertEqual(Set(file.owners(containing: chat)), [owner, secondOwner])
        XCTAssertEqual(file.board(owner: owner)?.entries.first?.light, .running, "Boards sind voneinander unabhängig")
        _ = JarvisBoardLogic.remove(&file, owner: secondOwner, sessionID: chat, now: t0)
        XCTAssertEqual(file.owners(containing: chat), [owner])
    }

    func testUnknownLightFromLaterVersionDoesNotBreakTheFile() throws {
        let json = """
        {"schema":"wm8.board/1","boards":[{"owner":"\(owner.uuidString)","isActive":true,
          "updatedAt":"2026-10-08T10:00:00Z",
          "entries":[{"sessionID":"\(chat.uuidString)","light":"blinking","updatedAt":"2026-10-08T10:00:00Z"}]}]}
        """
        let file = try JarvisBoardStore.decoder.decode(JarvisBoardFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.boards.first?.entries.first?.light, .running)
        XCTAssertEqual(file.boards.first?.entries.first?.mission, "")
    }
}

// MARK: - Store + Journal

final class JarvisBoardStoreTests: XCTestCase {
    private var directory: URL!
    private var boardURL: URL!
    private var journalURL: URL!
    private let owner = UUID()
    private let chat = UUID()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("board-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        boardURL = directory.appendingPathComponent("jarvis-board.json")
        journalURL = directory.appendingPathComponent("journal.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> JarvisBoardStore {
        JarvisBoardStore(fileURL: boardURL, journal: ChatsStatusJournal(fileURL: journalURL))
    }

    func testMutationPersistsAndJournalsOnlyRealChanges() throws {
        let store = makeStore()
        _ = try store.mutate { file, now in
            JarvisBoardLogic.set(&file, owner: owner, sessionID: chat, patch: JarvisBoardPatch(light: .needsYou), now: now)
        }
        _ = try store.mutate { file, now in
            JarvisBoardLogic.setActive(&file, owner: owner, active: true, now: now)   // schon aktiv
        }
        let onDisk = JarvisBoardStore.load(fileURL: boardURL)
        XCTAssertEqual(onDisk.schema, "wm8.board/1")
        XCTAssertEqual(onDisk.board(owner: owner)?.entries.first?.light, .needsYou)

        let events = ChatsStatusJournal.readAll(fileURL: journalURL)
        XCTAssertEqual(events.count, 1, "No-op-activate darf das Journal nicht füllen")
        XCTAssertEqual(events.first?.kind, "board")
        XCTAssertEqual(events.first?.op, "set")
        XCTAssertEqual(events.first?.owner, owner)
        XCTAssertEqual(events.first?.sessionID, chat)
        XCTAssertEqual(events.first?.light, "needsYou")
    }

    func testMissingFileReadsAsEmpty() {
        XCTAssertEqual(JarvisBoardStore.load(fileURL: boardURL), JarvisBoardFile())
    }

    func testCorruptFileIsQuarantinedNotSilentlyLost() throws {
        try Data("kein json".utf8).write(to: boardURL)
        XCTAssertTrue(JarvisBoardStore.load(fileURL: boardURL).boards.isEmpty)
        _ = try makeStore().mutate { file, now in
            JarvisBoardLogic.setActive(&file, owner: owner, active: true, now: now)
        }
        let quarantine = boardURL.appendingPathExtension("corrupt")
        XCTAssertEqual(try String(contentsOf: quarantine, encoding: .utf8), "kein json")
        XCTAssertEqual(JarvisBoardStore.load(fileURL: boardURL).board(owner: owner)?.isActive, true)
    }
}

// MARK: - App-Seite (Socket-Handler, pur)

final class JarvisBoardHandlerTests: XCTestCase {
    private var directory: URL!
    private var store: JarvisBoardStore!
    private var journalURL: URL!
    private let owner = UUID()
    private let chat = UUID()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("board-h-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        journalURL = directory.appendingPathComponent("journal.jsonl")
        store = JarvisBoardStore(fileURL: directory.appendingPathComponent("jarvis-board.json"),
                                 journal: ChatsStatusJournal(fileURL: journalURL))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func perform(_ method: String, params: [String: Any] = [:], enabled: Bool = true,
                         verified: Bool = true,
                         target: AgentControlRequestHandler.BoardTargetState = .available) -> ChatsControlResponse {
        AgentControlRequestHandler.performBoardMutation(
            ChatsControlRequest(requestID: UUID().uuidString,
                                actor: ChatsControlActor(sessionID: owner.uuidString, token: "t"),
                                method: method, params: .object(params)),
            store: store, enabled: enabled, verifiedOwner: verified ? owner : nil,
            targetState: { _ in target })
    }

    func testKillSwitchRejectsMutationsWithClearMessage() {
        let response = perform("board.activate", enabled: false)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "unsupported")
        XCTAssertTrue(response.error?.message.contains("jarvisBoardEnabled") ?? false)
        XCTAssertTrue(JarvisBoardStore.load(fileURL: store.fileURL).boards.isEmpty)
    }

    func testUnverifiedCallerIsRejected() {
        let response = perform("board.activate", verified: false)
        XCTAssertEqual(response.error?.code, "invalid", "ohne gültiges Token gehört dem Aufrufer kein Board")
    }

    func testOwnChatCannotStandOnOwnBoard() {
        let response = perform("board.set", params: ["targetSessionID": owner.uuidString])
        XCTAssertEqual(response.error?.code, "selfSend")
        XCTAssertEqual(ChatsControlErrorCode.selfSend.exitCode, ChatsCLIExit.conflict)
    }

    func testSetValidatesTargetAndLight() {
        XCTAssertEqual(perform("board.set", params: ["targetSessionID": chat.uuidString], target: .missing)
            .error?.code, "notFound")
        XCTAssertEqual(perform("board.set", params: ["targetSessionID": chat.uuidString], target: .archived)
            .error?.code, "notFound")
        XCTAssertEqual(perform("board.set", params: ["targetSessionID": chat.uuidString, "light": "rot"])
            .error?.code, "invalid")
        XCTAssertEqual(perform("board.set").error?.code, "invalid", "targetSessionID fehlt")
    }

    func testSetSanitizesAuthoritativelyAndReportsResult() {
        let response = perform("board.set", params: [
            "targetSessionID": chat.uuidString, "light": "needsYou",
            "needs": "Entscheidung\nOpener-Schluss", "mission": String(repeating: "x", count: 300),
        ])
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["op"]?.stringValue, "set")
        XCTAssertEqual(response.result?["changed"]?.boolValue, true)
        XCTAssertEqual(response.result?["isActive"]?.boolValue, true)
        XCTAssertEqual(response.result?["ref"]?.stringValue, ChatsOutput.shortID(chat))
        XCTAssertEqual(response.result?["entry"]?["needs"]?.stringValue, "Entscheidung Opener-Schluss")
        XCTAssertEqual(response.result?["entry"]?["mission"]?.stringValue?.count, 160)
    }

    func testRemoveClearActivateDeactivateRoundtrip() {
        _ = perform("board.set", params: ["targetSessionID": chat.uuidString])
        let removed = perform("board.remove", params: ["targetSessionID": chat.uuidString], target: .missing)
        XCTAssertTrue(removed.ok, "entfernen geht auch für verschwundene Chats")
        XCTAssertEqual(removed.result?["removedCount"]?.intValue, 1)
        XCTAssertEqual(perform("board.clear").result?["changed"]?.boolValue, false)
        XCTAssertEqual(perform("board.deactivate").result?["isActive"]?.boolValue, false)
        XCTAssertEqual(perform("board.activate").result?["isActive"]?.boolValue, true)
        XCTAssertEqual(perform("board.banane").error?.code, "unsupported")

        let ops = ChatsStatusJournal.readAll(fileURL: journalURL).compactMap(\.op)
        XCTAssertEqual(ops, ["set", "remove", "deactivate", "activate"])
    }
}

// MARK: - CLI-Parser

final class ChatsBoardParserTests: XCTestCase {
    func testReadDefaultsAndFlags() throws {
        XCTAssertEqual(try ChatsBoardParser.parse([]), .read(ChatsBoardReadOptions()))
        XCTAssertEqual(try ChatsBoardParser.parse(["--owner", "abcd1234", "--all", "--json"]),
                       .read(ChatsBoardReadOptions(owner: "abcd1234", all: true, json: true)))
        XCTAssertThrowsError(try ChatsBoardParser.parse(["--owner"]))
        XCTAssertThrowsError(try ChatsBoardParser.parse(["--banane"]))
    }

    func testSetParsesAllFieldsAndSanitizes() throws {
        let invocation = try ChatsBoardParser.parse([
            "set", "abcd1234", "--light", "done", "--mission", "Zeile\nzwei",
            "--needs", "- Freigabe", "--next", "", "--json",
        ])
        XCTAssertEqual(invocation, .set(ref: "abcd1234",
                                        patch: JarvisBoardPatch(light: .done, mission: "Zeile zwei",
                                                                needs: "- Freigabe", next: ""),
                                        json: true))
    }

    func testSetOmittedFieldsStayNil() throws {
        XCTAssertEqual(try ChatsBoardParser.parse(["set", "x1"]), .set(ref: "x1", patch: JarvisBoardPatch(), json: false))
    }

    func testSetRejectsBadInput() {
        XCTAssertThrowsError(try ChatsBoardParser.parse(["set", "x1", "--light", "rot"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("needsYou|running|done|parked"))
        }
        XCTAssertThrowsError(try ChatsBoardParser.parse(["set"]))
        XCTAssertThrowsError(try ChatsBoardParser.parse(["set", "a", "b"]))
        XCTAssertThrowsError(try ChatsBoardParser.parse(["set", "a", "--needs"]))
    }

    func testSimpleSubcommands() throws {
        XCTAssertEqual(try ChatsBoardParser.parse(["remove", "x1", "--json"]), .remove(ref: "x1", json: true))
        XCTAssertEqual(try ChatsBoardParser.parse(["clear"]), .clear(json: false))
        XCTAssertEqual(try ChatsBoardParser.parse(["activate", "--json"]), .activate(json: true))
        XCTAssertEqual(try ChatsBoardParser.parse(["deactivate"]), .deactivate(json: false))
        XCTAssertThrowsError(try ChatsBoardParser.parse(["remove"]))
        XCTAssertThrowsError(try ChatsBoardParser.parse(["clear", "x1"]))
    }
}

// MARK: - Lese-Vertrag (wm8.board/1)

final class ChatsBoardReadContractTests: XCTestCase {
    private let owner = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let otherOwner = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
    private let chatA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let chatB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
    private let t0 = Date(timeIntervalSince1970: 1_791_450_000)   // 2026-10-08

    private func entry(_ id: UUID, title: String) -> ChatsSessionEntry {
        ChatsSessionEntry(
            session: AgentChatSession(id: id, provider: .claude, projectID: UUID(), title: title,
                                      status: .running, groupName: nil, lastActivityAt: t0,
                                      titleIsAutoGenerated: nil, lastTurnAt: nil, kind: nil),
            projectName: "outreach", projectPath: "/p/outreach")
    }

    private func runtime(_ status: AgentSessionRuntimeStatus, since: Date?) -> ChatsRuntimeInfo {
        ChatsRuntimeInfo(status: status, source: "app", since: since, revision: nil,
                         transcriptPath: nil, transcriptSizeBytes: nil, availability: .available)
    }

    private func fixture() -> (JarvisBoardFile, JarvisBoard) {
        var file = JarvisBoardFile()
        _ = JarvisBoardLogic.set(&file, owner: owner, sessionID: chatA,
                                 patch: JarvisBoardPatch(light: .running, mission: "Kampagne Q4", next: "Leads prüfen"),
                                 now: t0)
        _ = JarvisBoardLogic.set(&file, owner: owner, sessionID: chatB,
                                 patch: JarvisBoardPatch(light: .needsYou, mission: "Opener",
                                                         needs: "Entscheidung Opener-Schluss"),
                                 now: t0.addingTimeInterval(30))
        _ = JarvisBoardLogic.set(&file, owner: otherOwner, sessionID: chatA, patch: JarvisBoardPatch(), now: t0)
        return (file, file.board(owner: owner)!)
    }

    func testReadJSONMatchesContract() throws {
        let (file, board) = fixture()
        let transitionAt = t0.addingTimeInterval(45)
        let transition = ChatsStatusJournalEntry(
            at: transitionAt, seq: 3, journalId: "gen1", sessionID: chatB,
            from: "working", to: "awaitingInput", signal: "permissionPrompt", source: "hook")
        let rows = ChatsBoardReadModel.rows(
            board: board, file: file,
            sessions: [chatA: entry(chatA, title: "Leads"), chatB: entry(chatB, title: "Copy")],
            runtime: [chatA: runtime(.working, since: t0), chatB: runtime(.awaitingInput, since: t0)],
            lastTransitions: [chatB: transition])
        let payload = ChatsBoardReadModel.readJSON(owner: owner, board: board, rows: rows, cursor: "gen1:3")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(ChatsOutput.encodeJSON(payload).utf8)) as? [String: Any])

        XCTAssertEqual(Set(json.keys), ["schema", "owner", "ownerRef", "isActive", "cursor", "entries"])
        XCTAssertEqual(json["schema"] as? String, "wm8.board/1")
        XCTAssertEqual(json["owner"] as? String, owner.uuidString)
        XCTAssertEqual(json["ownerRef"] as? String, "11111111")
        XCTAssertEqual(json["isActive"] as? Bool, true)
        XCTAssertEqual(json["cursor"] as? String, "gen1:3")

        let entries = try XCTUnwrap(json["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["ref"] as? String }, ["bbbbbbbb", "aaaaaaaa"], "needsYou vor running")
        let first = entries[0]
        XCTAssertEqual(Set(first.keys), ["ref", "sessionID", "title", "project", "light", "mission", "needs",
                                         "next", "updatedAt", "status", "statusSince", "otherOwners"])
        XCTAssertEqual(first["title"] as? String, "Copy")
        XCTAssertEqual(first["project"] as? String, "outreach")
        XCTAssertEqual(first["light"] as? String, "needsYou")
        XCTAssertEqual(first["needs"] as? String, "Entscheidung Opener-Schluss")
        XCTAssertEqual(first["status"] as? String, "awaitingInput")
        XCTAssertEqual(first["statusSince"] as? String, ChatsOutput.iso(transitionAt),
                       "der Journal-Wechsel ist genauer als die Probe-Schätzung")
        XCTAssertEqual(first["otherOwners"] as? [String], [])
        XCTAssertEqual(entries[1]["otherOwners"] as? [String], ["99999999"])
        XCTAssertEqual(entries[1]["statusSince"] as? String, ChatsOutput.iso(t0))
    }

    func testUnknownSessionStillRendersWithFallbacks() {
        let (file, board) = fixture()
        let rows = ChatsBoardReadModel.rows(board: board, file: file, sessions: [:], runtime: [:], lastTransitions: [:])
        let json = ChatsBoardReadModel.entryJSON(rows[0])
        XCTAssertEqual(json["title"] as? String, "bbbbbbbb", "Titel fällt auf den Kurz-Ref zurück")
        XCTAssertEqual(json["project"] as? String, "")
        XCTAssertEqual(json["status"] as? String, "unknown")
        XCTAssertTrue(json["statusSince"] is NSNull)
    }

    func testMissingBoardIsInactiveAndEmpty() throws {
        let payload = ChatsBoardReadModel.readJSON(owner: owner, board: nil, rows: [], cursor: nil)
        XCTAssertEqual(payload["isActive"] as? Bool, false)
        XCTAssertEqual((payload["entries"] as? [Any])?.count, 0)
        XCTAssertTrue(payload["cursor"] is NSNull)
        XCTAssertNotEqual(ChatsOutput.encodeJSON(payload), "{}", "muss serialisierbar sein")
    }

    func testAllJSONWrapsBoards() {
        let (file, _) = fixture()
        let boards = file.boards.map { ChatsBoardReadModel.boardJSON(owner: $0.owner, board: $0, rows: []) }
        let payload = ChatsBoardReadModel.allJSON(boards: boards, cursor: "g:1")
        XCTAssertEqual(payload["schema"] as? String, "wm8.board/1")
        XCTAssertEqual((payload["boards"] as? [[String: Any]])?.count, 2)
    }

    func testLastTransitionsIgnoreBoardEvents() {
        let conversation = ChatsStatusJournalEntry(at: t0, seq: 1, journalId: "g", sessionID: chatA,
                                                   from: "idle", to: "working", signal: "s", source: "hook")
        let board = ChatsStatusJournalEntry(at: t0, seq: 2, journalId: "g", sessionID: chatA, from: nil, to: nil,
                                            signal: "board.set", source: "board", kind: "board", op: "set",
                                            owner: owner, light: "done")
        XCTAssertEqual(ChatsBoardReadModel.lastTransitions([conversation, board])[chatA]?.seq, 1)
    }
}

// MARK: - Journal → since/watch

final class ChatsBoardJournalTests: XCTestCase {
    private var directory: URL!
    private var url: URL!
    private let owner = UUID()
    private let chat = UUID()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("board-j-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("journal.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testBoardEventsShareCursorWithConversationEventsAndSkipFromToGuard() {
        let journal = ChatsStatusJournal(fileURL: url)
        journal.append(sessionID: chat, from: "idle", to: "working", signal: "toolWillRun", source: "hook")
        let start = ChatsStatusJournal.currentCursor(fileURL: url)
        journal.appendBoard(op: "set", owner: owner, sessionID: chat, light: "needsYou")
        journal.appendBoard(op: "clear", owner: owner, sessionID: nil, light: nil)

        let result = ChatsStatusJournal.changes(since: start, fileURL: url)
        XCTAssertFalse(result.gap)
        XCTAssertEqual(result.entries.map(\.seq), [2, 3], "Board-Ereignisse fallen nicht dem from != to-Guard zum Opfer")

        let set = ChatsChangesCommand.changeJSON(result.entries[0])
        XCTAssertEqual(set["kind"] as? String, "board")
        XCTAssertEqual(set["op"] as? String, "set")
        XCTAssertEqual(set["owner"] as? String, owner.uuidString)
        XCTAssertEqual(set["ownerRef"] as? String, ChatsOutput.shortID(owner))
        XCTAssertEqual(set["ref"] as? String, ChatsOutput.shortID(chat))
        XCTAssertEqual(set["sessionID"] as? String, chat.uuidString)
        XCTAssertEqual(set["light"] as? String, "needsYou")
        XCTAssertEqual(set["seq"] as? Int, 2)
        XCTAssertNil(set["from"])
        XCTAssertNil(set["evidence"], "Board-Ereignisse sind keine Statusschätzung")

        let clear = ChatsChangesCommand.changeJSON(result.entries[1])
        XCTAssertEqual(clear["op"] as? String, "clear")
        XCTAssertNil(clear["ref"])
        XCTAssertNil(clear["sessionID"])
        XCTAssertNil(clear["light"])
    }

    func testConversationEventShapeIsUnchanged() {
        let journal = ChatsStatusJournal(fileURL: url)
        journal.append(sessionID: chat, from: "working", to: "idle", signal: "turnStopped", source: "hook")
        let json = ChatsChangesCommand.changeJSON(ChatsStatusJournal.readAll(fileURL: url)[0])
        XCTAssertEqual(Set(json.keys), ["seq", "at", "ref", "sessionID", "kind", "signal", "evidence", "from", "to"])
        XCTAssertEqual(json["kind"] as? String, "conversation")
        let raw = try? String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw?.contains("\"kind\"") ?? true, "Statuszeilen bleiben auf Disk wie bisher")
    }

    func testOldLinesWithoutBoardFieldsStillDecode() {
        let line = #"{"at":"2026-10-08T10:00:00Z","seq":1,"journalId":"g","sessionID":"\#(chat.uuidString)","from":"idle","to":"working","signal":"s","source":"hook"}"#
        try? Data((line + "\n").utf8).write(to: url)
        let entries = ChatsStatusJournal.readAll(fileURL: url)
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].kind)
        XCTAssertFalse(entries[0].isBoardEvent)
    }

    func testStatusHistoryExcludesBoardEvents() {
        let journal = ChatsStatusJournal(fileURL: url)
        journal.append(sessionID: chat, from: "idle", to: "working", signal: "s", source: "hook")
        journal.appendBoard(op: "set", owner: owner, sessionID: chat, light: "running")
        XCTAssertEqual(ChatsStatusJournal.recent(sessionID: chat, fileURL: url).count, 1)
    }
}

// MARK: - Kill-Switch

final class JarvisBoardSettingsTests: XCTestCase {
    func testDefaultIsOnAndExplicitNoTurnsItOff() {
        XCTAssertTrue(JarvisBoardSettings.isEnabled(read: { _ in nil }))
        XCTAssertTrue(JarvisBoardSettings.isEnabled(read: { _ in true }))
        XCTAssertFalse(JarvisBoardSettings.isEnabled(read: { _ in false }))
        XCTAssertEqual(JarvisBoardSettings.defaultsKey, "jarvisBoardEnabled")
    }

    func testDisabledReadShowsNoBoardWithoutTouchingTheFile() {
        var file = JarvisBoardFile()
        _ = JarvisBoardLogic.setActive(&file, owner: UUID(), active: true, now: Date())
        var loaded = false
        let hidden = ChatsBoardCommand.visibleFile(enabled: false) { loaded = true; return file }
        XCTAssertTrue(hidden.boards.isEmpty)
        XCTAssertFalse(loaded)
        XCTAssertEqual(ChatsBoardCommand.visibleFile(enabled: true) { file }, file)
    }
}
