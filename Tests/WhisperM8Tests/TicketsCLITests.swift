import XCTest
@testable import WhisperM8

final class TicketsCLITests: XCTestCase {
    // MARK: Umgebung

    private let jon = UUID(uuidString: "7493E390-EDEB-4CC0-AEBE-68EF61F356EE")!
    private let dex = UUID(uuidString: "840BFE4C-0000-4000-8000-000000000001")!
    private let ole = UUID(uuidString: "B0096DCA-0000-4000-8000-000000000002")!
    private let jarvis = UUID(uuidString: "A37D241B-0000-4000-8000-000000000003")!
    private let giuliano = TicketPerson(id: "u1", name: "Giuliano Costa")
    private let project = "/Users/g/repos/whisperm8"

    private final class World {
        let source = TicketSourceStub()
        var config = TicketConfig()
        var savedConfigs: [TicketConfig] = []
        var storedKey: String? = "lin_api_alt"
        var writtenKeys: [String] = []
        var writeSucceeds = true
        var validation: Result<TicketAccount, TicketSourceError> =
            .success(TicketAccount(userName: "Giuliano Costa", workspace: "Test (linear.app/test)", isAdmin: true))
        var chats: [TicketChat] = []
        var appReachable = true
        var caller: UUID?
        var directory = "/Users/g/repos/whisperm8"
        var stdin = ""
        var files: [String: String] = [:]
    }

    private func makeWorld() -> World {
        let world = World()
        world.config.set(team: "WM8", forProject: project)
        world.caller = jon
        world.chats = [
            chat(jon, "6 Jon · WM8-23 Linear", state: .working),
            chat(dex, "3 Dex · WM8-10 Abnahme", state: .idle),
            chat(ole, "2 Ole · Terminal-Tab", state: .idle),
            chat(jarvis, "Jarvis: Supervisor WhisperM8", state: .idle),
        ]
        return world
    }

    private func chat(_ id: UUID, _ title: String, state: TicketChatState?, running: Bool = true) -> TicketChat {
        TicketChat(id: id, title: title, projectName: "whisperm8", projectPath: project, state: state, isRunning: running)
    }

    private func environment(_ world: World) -> TicketsCLIEnvironment {
        TicketsCLIEnvironment(
            source: world.source,
            config: { world.config },
            saveConfig: { world.config = $0; world.savedConfigs.append($0) },
            credential: TicketCredentialStore(
                read: { world.storedKey },
                write: { key in
                    world.writtenKeys.append(key)
                    if world.writeSucceeds { world.storedKey = key }
                    return world.writeSucceeds
                },
                delete: { world.storedKey = nil }),
            validateKey: { _ in world.validation },
            chats: { (world.chats, world.appReachable) },
            callerChatID: { world.caller },
            currentDirectory: { world.directory },
            readStdin: { world.stdin },
            readFile: { world.files[$0] },
            now: { Date(timeIntervalSince1970: 1_794_000_000) }
        )
    }

    private func run(_ arguments: [String], _ world: World) async throws -> TicketsCLIRunner.Output {
        await TicketsCLIRunner.execute(try TicketsCLIArguments.parse(arguments), environment: environment(world))
    }

    private func context(_ ticket: Ticket) -> TicketContext {
        TicketContext(ticket: ticket, team: "WM8", statuses: TicketFixtures.statuses)
    }

    /// Schreibende Aufrufe, ohne die Lese-Aufrufe davor.
    private func writes(_ world: World) -> [String] {
        world.source.calls.filter { !$0.hasPrefix("ticket ") && !$0.hasPrefix("board ") && !$0.hasPrefix("person ") && $0 != "linked" && $0 != "account" }
    }

    // MARK: Argumente

    func testParseReadCommands() throws {
        XCTAssertEqual(try TicketsCLIArguments.parse([]), .help)
        XCTAssertEqual(try TicketsCLIArguments.parse(["board", "--team", "wm8", "--json"]), .board(team: "WM8", all: false, json: true))
        var filter = TicketsListFilter()
        filter.person = "me"
        filter.agent = .withoutAgent
        filter.project = "Neustart ohne Chatverlust"
        XCTAssertEqual(try TicketsCLIArguments.parse(["list", "--mine", "--no-agent", "--project", "Neustart ohne Chatverlust"]),
                       .list(team: nil, filter: filter, json: false))
        XCTAssertEqual(try TicketsCLIArguments.parse(["show", "wm8-12"]), .show(key: "WM8-12", json: false), "Nummer wird groß geschrieben")
    }

    func testParseWriteCommands() throws {
        XCTAssertEqual(try TicketsCLIArguments.parse(["link", "WM8-12", "--no-status", "--chat", "840b"]),
                       .link(key: "WM8-12", chat: "840b", keepStatus: true))
        XCTAssertEqual(try TicketsCLIArguments.parse(["done", "WM8-12", "--status", "Merge-bereit", "--note", "Branch steht."]),
                       .done(key: "WM8-12", chat: nil, status: "Merge-bereit", note: .literal("Branch steht."), force: false))
        XCTAssertEqual(try TicketsCLIArguments.parse(["comment", "WM8-12", "-"]), .comment(key: "WM8-12", text: .stdin), "- heißt stdin, ist keine Option")
        XCTAssertEqual(try TicketsCLIArguments.parse(["note", "WM8-12", "@stand.md"]), .note(key: "WM8-12", text: .file("stand.md")))
        XCTAssertEqual(try TicketsCLIArguments.parse(["comment", "WM8-12", "--", "@Giuliano bitte prüfen"]),
                       .comment(key: "WM8-12", text: .literal("@Giuliano bitte prüfen")), "nach -- ist alles wörtlicher Text")
        XCTAssertEqual(try TicketsCLIArguments.parse(["comment", "WM8-12", "--", "--force war nötig"]),
                       .comment(key: "WM8-12", text: .literal("--force war nötig")))
        XCTAssertEqual(try TicketsCLIArguments.parse(["status", "WM8-12", "Done", "--json"]), .status(key: "WM8-12", name: "Done", force: false),
                       "--json geht bei jedem Befehl")
        XCTAssertEqual(try TicketsCLIArguments.parse(["status", "WM8-12", "Done", "--force"]), .status(key: "WM8-12", name: "Done", force: true))
        XCTAssertTrue(TicketsCLIArguments.wantsJSON(["status", "WM8-12", "Done", "--json"]))
        XCTAssertFalse(TicketsCLIArguments.wantsJSON(["comment", "WM8-12", "--", "--json"]), "hinter -- ist es Text")
        XCTAssertEqual(try TicketsCLIArguments.parse(["label", "WM8-12", "--add", "Handtest, Bug", "--remove", "Feature"]),
                       .label(key: "WM8-12", add: ["Handtest", "Bug"], remove: ["Feature"]))
        var options = TicketsNewOptions()
        options.title = "Neuer Punkt"
        options.priority = 2
        options.labels = ["Bug"]
        options.assignee = "me"
        XCTAssertEqual(try TicketsCLIArguments.parse(["new", "Neuer Punkt", "--priority", "high", "--labels", "Bug", "--assignee", "me"]), .new(options))
    }

    func testDuplicateOptionIsNamed() {
        XCTAssertThrowsError(try TicketsCLIArguments.parse(["board", "--team", "A", "--team", "B"])) { error in
            XCTAssertEqual(error as? TicketsCLIArguments.ParseError, .usage("--team ist doppelt angegeben"))
        }
    }

    func testParseErrors() {
        let cases: [[String]] = [
            ["show"], ["show", "abc"], ["show", "WM8-1", "extra"], ["board", "--falsch"], ["list", "--mine", "--unassigned"],
            ["label", "WM8-1"], ["new", "Titel", "--priority", "sofort"], ["setup", "--project", "/x"], ["link", "WM8-1", "--chat"],
            ["gibtsnicht"], ["new", "  "],
        ]
        for arguments in cases {
            XCTAssertThrowsError(try TicketsCLIArguments.parse(arguments), "\(arguments)") { error in
                guard case TicketsCLIArguments.ParseError.usage = error else { return XCTFail("\(arguments): \(error)") }
            }
        }
    }

    // MARK: Verknüpfen

    func testLinkStartsTicketThatIsNotInProgress() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12, status: "Todo")) }
        let output = try await run(["link", "WM8-12"], world)
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(writes(world), ["saveLink id-12 6 Jon aktiv", "setStatus id-12 s2"], "Todo → erster Status „in Arbeit“")
        XCTAssertTrue(output.stdout.contains("Status: In Progress"))
    }

    func testLinkKeepsStatusWhenAlreadyStartedOrAsked() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12, status: "Merge-bereit")) }
        _ = try await run(["link", "WM8-12"], world)
        XCTAssertEqual(writes(world), ["saveLink id-12 6 Jon aktiv"], "schon in Arbeit: Status bleibt")

        let second = makeWorld()
        second.source.onTicket = { _ in self.context(TicketFixtures.ticket(12, status: "Backlog")) }
        _ = try await run(["link", "WM8-12", "--no-status"], second)
        XCTAssertEqual(writes(second), ["saveLink id-12 6 Jon aktiv"])
    }

    func testLinkWarnsAboutOtherAgentAndUsesChatFlag() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(10, status: "In Progress", links: [TicketFixtures.link(self.dex)])) }
        let output = try await run(["link", "WM8-10", "--chat", "b0096"], world)
        XCTAssertEqual(writes(world), ["saveLink id-10 2 Ole aktiv"])
        XCTAssertTrue(output.stdout.contains("Hinweis: An dem Ticket sitzt schon 3 Dex."))
    }

    func testLinkOutsideAChatNeedsChatFlag() async throws {
        let world = makeWorld()
        world.caller = nil
        let output = try await run(["link", "WM8-12"], world)
        XCTAssertEqual(output.exitCode, TicketsCLIExit.usage)
        XCTAssertTrue(output.stderr.contains("--chat"))
        XCTAssertTrue(world.source.calls.isEmpty, "kein Aufruf, bevor der Chat feststeht")
    }

    func testChatRefAmbiguousAndMissing() async throws {
        let world = makeWorld()
        world.chats.append(chat(UUID(uuidString: "840BFE4C-1111-4000-8000-000000000009")!, "9 Zoe", state: .idle))
        let ambiguous = try await run(["mine", "--chat", "840b"], world)
        XCTAssertEqual(ambiguous.exitCode, TicketsCLIExit.conflict)
        let missing = try await run(["mine", "--chat", "ffff"], world)
        XCTAssertEqual(missing.exitCode, TicketsCLIExit.notFound)
        XCTAssertEqual(TicketChatRef.resolve("84", in: world.chats), .none, "unter vier Zeichen wird nicht geraten")
    }

    // MARK: Beenden, Status, Text

    func testDoneEndsLinkSetsNoteAndStatus() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in
            self.context(TicketFixtures.ticket(12, status: "In Progress", description: "**Stand 13.11.2026:** in Arbeit.\n\n## Ziel\nText",
                                               links: [TicketFixtures.link(self.jon)]))
        }
        let output = try await run(["done", "WM8-12", "--status", "merge-bereit", "--note", "Branch steht."], world)
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(writes(world).count, 3)
        XCTAssertEqual(writes(world)[0], "saveLink id-12 6 Jon beendet")
        XCTAssertTrue(writes(world)[1].hasPrefix("description id-12 **Stand "), writes(world)[1])
        XCTAssertTrue(writes(world)[1].hasSuffix(":** Branch steht.\n\n## Ziel\nText"), "alte Stand-Zeile ersetzt, Rest bleibt")
        XCTAssertEqual(writes(world)[2], "setStatus id-12 s3")
        XCTAssertTrue(output.stdout.contains("Status: Merge-bereit"))
    }

    func testDoneWithUnknownStatusChangesNothing() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12, status: "In Progress", links: [TicketFixtures.link(self.jon)])) }
        let output = try await run(["done", "WM8-12", "--status", "Fertig"], world)
        XCTAssertEqual(output.exitCode, TicketsCLIExit.notFound)
        XCTAssertTrue(output.stderr.contains("Möglich: Backlog, Todo, In Progress, Merge-bereit, Done, Canceled"))
        XCTAssertTrue(writes(world).isEmpty, "erst prüfen, dann schreiben")
    }

    func testDoneWithoutLinkOnlySetsStatus() async throws {
        let world = makeWorld()
        world.caller = jarvis
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12, status: "Merge-bereit")) }
        let output = try await run(["done", "WM8-12", "--status", "Done", "--chat", "7493"], world)
        XCTAssertEqual(writes(world), ["setStatus id-12 s4"], "keine Verknüpfung anlegen, nur um sie zu beenden")
        XCTAssertTrue(output.stdout.contains("war nicht (mehr) verknüpft"), "nichts behaupten, was nicht passiert ist")
    }

    func testOnlyTheSupervisorCompletesATicket() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12, status: "In Progress", links: [TicketFixtures.link(self.jon)])) }

        // Arbeitender Chat: Absage, bevor irgendetwas geschrieben ist.
        let viaDone = try await run(["done", "WM8-12", "--status", "Done"], world)
        XCTAssertEqual(viaDone.exitCode, TicketsCLIExit.conflict)
        XCTAssertTrue(viaDone.stderr.contains("setzt der Supervisor"), viaDone.stderr)
        let viaStatus = try await run(["status", "WM8-12", "Done"], world)
        XCTAssertEqual(viaStatus.exitCode, TicketsCLIExit.conflict)
        XCTAssertTrue(writes(world).isEmpty)

        // Abgeben darf er.
        _ = try await run(["done", "WM8-12", "--status", "Merge-bereit"], world)
        XCTAssertEqual(writes(world), ["saveLink id-12 6 Jon beendet", "setStatus id-12 s3"])

        // Der Supervisor, ein Mensch im Terminal und ein ausdrückliches --force dürfen.
        for caller in [jarvis, nil] as [UUID?] {
            let other = makeWorld()
            other.caller = caller
            other.source.onTicket = { _ in self.context(TicketFixtures.ticket(12, status: "Merge-bereit")) }
            let output = try await run(["status", "WM8-12", "Done"], other)
            XCTAssertEqual(output.exitCode, 0, "\(String(describing: caller))")
            XCTAssertEqual(writes(other), ["setStatus id-12 s4"])
        }
        let forced = makeWorld()
        forced.source.onTicket = { _ in self.context(TicketFixtures.ticket(12, status: "Merge-bereit")) }
        let output = try await run(["status", "WM8-12", "Done", "--force"], forced)
        XCTAssertEqual(output.exitCode, 0)
    }

    func testShortNameDropsTheTicketNumber() {
        func name(_ title: String) -> String { chat(UUID(), title, state: .idle).shortName }
        XCTAssertEqual(name("WM8-16 Fin · Insel: Tastatur-Entwurf"), "Fin")
        XCTAssertEqual(name("Ole · Terminal-Tab: fertig"), "Ole")
        XCTAssertEqual(name("6 Jon · Linear"), "6 Jon", "eine laufende Nummer ist kein Ticket-Kürzel")
        XCTAssertEqual(name("Jarvis: Supervisor WhisperM8"), "Jarvis: Supervisor WhisperM8")
        XCTAssertEqual(name("WM8-16 · nur Nummer"), "WM8-16", "bliebe sonst nichts übrig, steht die Nummer da")
    }

    func testSecondDoneKeepsTheEndTime() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12, status: "Merge-bereit", links: [TicketFixtures.link(self.jon, active: false)])) }
        _ = try await run(["done", "WM8-12"], world)
        XCTAssertTrue(writes(world).isEmpty, "schon beendet: die Zeit der Verknüpfung bleibt")
    }

    func testDoneWithUnreadableNoteChangesNothing() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12, status: "In Progress", links: [TicketFixtures.link(self.jon)])) }
        let missing = try await run(["done", "WM8-12", "--note", "@fehlt.md", "--status", "Merge-bereit"], world)
        XCTAssertEqual(missing.exitCode, TicketsCLIExit.usage)
        let blank = try await run(["done", "WM8-12", "--note", "   "], world)
        XCTAssertEqual(blank.exitCode, TicketsCLIExit.usage)
        XCTAssertTrue(writes(world).isEmpty, "die Verknüpfung darf nicht schon beendet sein, wenn der Text fehlt")
    }

    func testWriteCommandsAnswerInJSON() async throws {
        let world = makeWorld()
        world.caller = nil
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12, status: "Merge-bereit")) }
        world.source.onCreate = { draft in TicketFixtures.ticket(70, title: draft.title) }
        let arguments = try TicketsCLIArguments.parse(["status", "WM8-12", "Done", "--json"])
        let status = await TicketsCLIRunner.execute(arguments, environment: environment(world), json: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(status.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["key"] as? String, "WM8-12")
        XCTAssertEqual(object["message"] as? String, "WM8-12: Merge-bereit → Done")

        let created = await TicketsCLIRunner.execute(try TicketsCLIArguments.parse(["new", "Neu", "--json"]), environment: environment(world), json: true)
        let made = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(created.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(made["key"] as? String, "WM8-70", "die neue Nummer steht im Feld key")
    }

    func testLinkReportsWhenStatusChangeFails() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12, status: "In Progress")) }
        world.source.writeError = .network("-1009")
        let output = try await run(["link", "WM8-12"], world)
        XCTAssertEqual(output.exitCode, TicketsCLIExit.unavailable)
        XCTAssertEqual(writes(world), ["saveLink id-12 6 Jon aktiv"], "nach dem ersten Fehler kein weiterer Versuch")
    }

    func testStatusNoOpAndChange() async throws {
        let world = makeWorld()
        world.caller = jarvis
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12, status: "Merge-bereit")) }
        let same = try await run(["status", "WM8-12", "Merge-bereit"], world)
        XCTAssertTrue(same.stdout.contains("steht schon auf"))
        XCTAssertTrue(writes(world).isEmpty)
        let changed = try await run(["status", "WM8-12", "done"], world)
        XCTAssertEqual(changed.stdout, "WM8-12: Merge-bereit → Done")
        XCTAssertEqual(writes(world), ["setStatus id-12 s4"])
    }

    func testCommentFromStdinAndFileAndEmpty() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12)) }
        world.stdin = "  aus stdin\n"
        world.files["notiz.md"] = "aus Datei"
        _ = try await run(["comment", "WM8-12", "-"], world)
        _ = try await run(["comment", "WM8-12", "@notiz.md"], world)
        XCTAssertEqual(writes(world), ["comment id-12 aus stdin", "comment id-12 aus Datei"])

        let missing = try await run(["comment", "WM8-12", "@fehlt.md"], world)
        XCTAssertEqual(missing.exitCode, TicketsCLIExit.usage)
        world.stdin = "   "
        let empty = try await run(["note", "WM8-12", "-"], world)
        XCTAssertEqual(empty.exitCode, TicketsCLIExit.usage)
        XCTAssertEqual(writes(world).count, 2, "leerer Text schreibt nichts")
    }

    func testUnlinkRemovesOnlyOwnLinks() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in
            self.context(TicketFixtures.ticket(10, status: "In Progress",
                                               links: [TicketFixtures.link(self.dex, id: "att-dex"), TicketFixtures.link(self.jon, id: "att-jon")]))
        }
        _ = try await run(["unlink", "WM8-10"], world)
        XCTAssertEqual(writes(world), ["removeLink att-jon"])
    }

    // MARK: Anlegen und zuordnen

    func testNewUsesTeamOfTheCurrentFolder() async throws {
        let world = makeWorld()
        world.directory = project + "/.claude/worktrees/ticket-board"
        world.source.onPerson = { _ in self.giuliano }
        var received: TicketDraft?
        world.source.onCreate = { draft in received = draft; return TicketFixtures.ticket(70, title: draft.title) }
        let output = try await run(["new", "Neuer Punkt", "--description", "Text", "--assignee", "me", "--labels", "Bug", "--priority", "low"], world)
        XCTAssertEqual(received, TicketDraft(team: "WM8", title: "Neuer Punkt", description: "Text", project: nil, statusName: nil,
                                             priority: 4, labels: ["Bug"], assigneeID: "u1"))
        XCTAssertTrue(output.stdout.hasPrefix("WM8-70 angelegt: Neuer Punkt"))
    }

    func testTeamUnclearIsAUsageError() async throws {
        let world = makeWorld()
        world.config = TicketConfig()
        let output = try await run(["board"], world)
        XCTAssertEqual(output.exitCode, TicketsCLIExit.usage)
        XCTAssertTrue(output.stderr.contains("tickets setup --project"))
        XCTAssertTrue(world.source.calls.isEmpty)
    }

    func testAssignMeNoneAndAmbiguous() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12)) }
        world.source.onPerson = { query in
            if query == "xen" { throw TicketSourceError.ambiguous("„xen“ passt auf mehrere Personen: Xenia Muster, Xeno Suter") }
            return self.giuliano
        }
        _ = try await run(["assign", "WM8-12", "me"], world)
        _ = try await run(["assign", "WM8-12", "none"], world)
        XCTAssertEqual(writes(world), ["assign id-12 u1", "assign id-12 niemand"])
        let ambiguous = try await run(["assign", "WM8-12", "xen"], world)
        XCTAssertEqual(ambiguous.exitCode, TicketsCLIExit.conflict)
        XCTAssertEqual(writes(world).count, 2)
    }

    // MARK: Lesen

    private func boardWorld() -> World {
        let world = makeWorld()
        world.source.onBoard = { _ in
            TicketFixtures.snapshot([
                TicketFixtures.ticket(23, status: "In Progress", title: "Linear testen", priority: 2, assignee: self.giuliano, links: [TicketFixtures.link(self.jon)]),
                TicketFixtures.ticket(10, status: "In Progress", title: "Abnahme", links: [TicketFixtures.link(self.dex)], blocked: true),
                TicketFixtures.ticket(7, status: "Todo", title: "Erster Lauf", priority: 2, assignee: self.giuliano),
                TicketFixtures.ticket(13, status: "Backlog", title: "Merge"),
                TicketFixtures.ticket(29, status: "Done", title: "Terminal-Tab", links: [TicketFixtures.link(self.ole)]),
            ])
        }
        return world
    }

    func testBoardText() async throws {
        let output = try await run(["board"], boardWorld())
        let text = output.stdout
        XCTAssertTrue(text.contains("== In Arbeit  (2 Tickets, 2 mit Agent)"), text)
        XCTAssertTrue(text.contains("6 Jon (arbeitet)"))
        XCTAssertTrue(text.contains("In Progress, blockiert"))
        XCTAssertTrue(text.contains("== Als Nächstes  (1 Tickets, 0 mit Agent)"))
        XCTAssertTrue(text.contains("kein Agent"))
        XCTAssertTrue(text.contains("== Laufende Chats ohne offenes Ticket (1)"))
        XCTAssertTrue(text.contains("zuletzt an WM8-29 (Done)"))
        XCTAssertTrue(text.contains("== Supervisor (1, ohne Ticket vorgesehen)"))
        XCTAssertFalse(text.contains("Erledigt, mit Chat-Spur"), "erledigte Tickets nur mit --all")
        XCTAssertLessThan(text.range(of: "WM8-23")!.lowerBound, text.range(of: "WM8-10")!.lowerBound, "höhere Priorität zuerst")
    }

    func testHandedOverTicketIsNotWithoutAgent() async throws {
        let world = makeWorld()
        world.source.onBoard = { _ in
            TicketFixtures.snapshot([
                TicketFixtures.ticket(29, status: "Merge-bereit", title: "Terminal-Tab", links: [
                    TicketChatLink(id: "a1", chatID: self.ole, isActive: false, title: "Chat: 2 Ole · Terminal-Tab",
                                   subtitle: "beendet am 14.11. 01:10 · WhisperM8", creatorName: nil),
                ]),
                TicketFixtures.ticket(9, status: "In Progress", title: "Anleitung"),
            ])
        }
        let board = try await run(["board"], world)
        XCTAssertTrue(board.stdout.contains("abgegeben von 2 Ole"), board.stdout)
        XCTAssertTrue(board.stdout.contains("zuletzt an WM8-29 (Merge-bereit)"), "der Chat wartet auf den Merge, er war nicht „nie verknüpft“")
        let open = try await run(["list", "--no-agent"], world)
        XCTAssertTrue(open.stdout.hasPrefix("WM8-9"))
        XCTAssertFalse(open.stdout.contains("WM8-29"), "wartet auf den Merge, nicht auf einen Chat")
    }

    func testBoardWithExplicitTeamUsesThatTeamsProject() async throws {
        let world = makeWorld()
        world.config.set(team: "DS", forProject: "/Users/g/repos/ListM8")
        world.chats.append(TicketChat(id: UUID(), title: "1 Ana · Slack", projectName: "ListM8", projectPath: "/Users/g/repos/ListM8",
                                      state: .idle, isRunning: true))
        world.source.onBoard = { team in TicketBoardSnapshot(team: team, statuses: [], tickets: [], fetchedAt: Date()) }
        let output = try await run(["board", "--team", "DS"], world)
        XCTAssertTrue(output.stdout.contains("1 Ana"), "Chats des genannten Teams, nicht des aktuellen Ordners")
        XCTAssertFalse(output.stdout.contains("2 Ole"))
    }

    func testBoardWithoutAppSaysSo() async throws {
        let world = boardWorld()
        world.appReachable = false
        world.chats = world.chats.map { var chat = $0; chat.state = nil; chat.isRunning = false; return chat }
        let output = try await run(["board"], world)
        XCTAssertTrue(output.stdout.contains("6 Jon (Zustand unbekannt)"))
        XCTAssertTrue(output.stdout.contains("Die App ist nicht erreichbar"))
        XCTAssertFalse(output.stdout.contains("ohne offenes Ticket"))
    }

    func testBoardJSON() async throws {
        let output = try await run(["board", "--json", "--all"], boardWorld())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(object["team"] as? String, "WM8")
        XCTAssertEqual(object["appReachable"] as? Bool, true)
        let tickets = try XCTUnwrap(object["tickets"] as? [[String: Any]])
        XCTAssertEqual(tickets.map { $0["key"] as? String }, ["WM8-23", "WM8-10", "WM8-7", "WM8-13"])
        let agent = try XCTUnwrap((tickets[0]["agents"] as? [[String: Any]])?.first)
        XCTAssertEqual(agent["state"] as? String, "working")
        XCTAssertEqual(agent["onThisMac"] as? Bool, true)
        XCTAssertEqual((object["chatsWithoutOpenTicket"] as? [[String: Any]])?.first?["earlier"] as? [String], ["WM8-29 (Done)"])
        XCTAssertEqual((object["closedWithLink"] as? [[String: Any]])?.count, 1)
    }

    func testListFilters() async throws {
        let world = boardWorld()
        world.source.onPerson = { _ in self.giuliano }
        let mineOpen = try await run(["list", "--mine", "--no-agent"], world)
        XCTAssertTrue(mineOpen.stdout.hasPrefix("WM8-7"), mineOpen.stdout)
        XCTAssertEqual(mineOpen.stdout.split(separator: "\n").count, 1)
        let unassignedStarted = try await run(["list", "--unassigned", "--status", "started"], world)
        XCTAssertTrue(unassignedStarted.stdout.hasPrefix("WM8-10"))
        let none = try await run(["list", "--project", "Gibt es nicht"], world)
        XCTAssertEqual(none.stdout, "(keine Tickets für diesen Filter)")
    }

    func testMineAndShow() async throws {
        let world = makeWorld()
        world.source.onLinked = { _ in [TicketFixtures.ticket(23, status: "In Progress", links: [TicketFixtures.link(self.jon)])] }
        let mine = try await run(["mine"], world)
        XCTAssertTrue(mine.stdout.contains("WM8-23") && mine.stdout.contains("arbeitet seit 14.11. 00:51"))
        world.source.onTicket = { _ in
            self.context(TicketFixtures.ticket(23, status: "In Progress", description: "## Ziel\nText", assignee: self.giuliano,
                                               links: [TicketFixtures.link(self.jon), TicketFixtures.link(self.dex, active: false)]))
        }
        let show = try await run(["show", "WM8-23"], world)
        XCTAssertTrue(show.stdout.contains("Agent: 6 Jon (arbeitet)"))
        XCTAssertTrue(show.stdout.contains("Früher: Chat (beendet am 14.11. 01:10)"))
        XCTAssertTrue(show.stdout.hasSuffix("## Ziel\nText"))
    }

    // MARK: Einrichten und Fehler

    func testSetupStoresOnlyAValidatedKey() async throws {
        let world = makeWorld()
        world.stdin = "lin_api_neu\n"
        let stored = try await run(["setup", "--key-stdin"], world)
        XCTAssertEqual(stored.exitCode, 0)
        XCTAssertEqual(world.writtenKeys, ["lin_api_neu"])
        XCTAssertFalse(stored.stdout.contains("lin_api"), "der Key steht nie in der Ausgabe")

        world.validation = .failure(.unauthorized)
        world.stdin = "lin_api_falsch"
        let rejected = try await run(["setup", "--key-stdin"], world)
        XCTAssertEqual(rejected.exitCode, TicketsCLIExit.unavailable)
        XCTAssertEqual(world.writtenKeys, ["lin_api_neu"], "abgelehnter Key wird nicht gespeichert")
        XCTAssertEqual(world.storedKey, "lin_api_neu")

        world.stdin = "kein key mit \"zeichen\""
        let invalid = try await run(["setup", "--key-stdin"], world)
        XCTAssertEqual(invalid.exitCode, TicketsCLIExit.usage)
    }

    func testSetupProjectMappingResolvesRelativePaths() async throws {
        let world = makeWorld()
        world.config = TicketConfig()
        world.directory = "/Users/g/repos"
        let output = try await run(["setup", "--project", "ListM8", "--team", "ds"], world)
        XCTAssertEqual(world.savedConfigs.last?.teamsByProjectPath, ["/Users/g/repos/ListM8": "DS"])
        XCTAssertTrue(output.stdout.contains("/Users/g/repos/ListM8 gehört zum Team DS."))
    }

    func testDoctor() async throws {
        let world = boardWorld()
        let healthy = try await run(["doctor"], world)
        XCTAssertEqual(healthy.exitCode, 0)
        XCTAssertTrue(healthy.stdout.contains("ok     Team WM8       4 offene Tickets, 2 mit Agent"), healthy.stdout)

        world.storedKey = nil
        let noKey = try await run(["doctor"], world)
        XCTAssertEqual(noKey.exitCode, TicketsCLIExit.unavailable)
        XCTAssertTrue(noKey.stdout.contains("FEHLER Linear-Key"), "der Bericht steht auf stdout, der Exit-Code zeigt das Problem")

        let asJSON = try await run(["doctor", "--json"], world)
        XCTAssertEqual(asJSON.exitCode, TicketsCLIExit.unavailable)
        let checks = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(asJSON.stdout.utf8)) as? [[String: Any]])
        XCTAssertEqual(checks.first?["ok"] as? Bool, false, "auch im Fehlerfall lesbares JSON auf stdout")

        world.storedKey = "lin_api_alt"
        world.source.onAccount = { throw TicketSourceError.unauthorized }
        let rejected = try await run(["doctor"], world)
        XCTAssertTrue(rejected.stdout.contains("FEHLER Linear-Zugang"))
    }

    func testSourceErrorsBecomeExitCodes() async throws {
        let world = makeWorld()
        let cases: [(TicketSourceError, Int32)] = [
            (.notFound("WM8-9"), TicketsCLIExit.notFound), (.ambiguous("x"), TicketsCLIExit.conflict),
            (.notConfigured, TicketsCLIExit.unavailable), (.unauthorized, TicketsCLIExit.unavailable),
            (.rateLimited, TicketsCLIExit.unavailable), (.network("-1009"), TicketsCLIExit.unavailable),
        ]
        for (error, code) in cases {
            world.source.onTicket = { _ in throw error }
            let output = try await run(["show", "WM8-9"], world)
            XCTAssertEqual(output.exitCode, code, "\(error)")
            XCTAssertEqual(output.stderr, error.message)
            XCTAssertTrue(output.stdout.isEmpty)
        }
    }

    func testWriteFailureIsReported() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12, status: "Todo")) }
        world.source.writeError = .rejected("Status passt nicht zum Team.")
        let output = try await run(["link", "WM8-12"], world)
        XCTAssertEqual(output.exitCode, TicketsCLIExit.unavailable)
        XCTAssertEqual(output.stderr, "Linear lehnt ab: Status passt nicht zum Team.")
    }

    func testCommandIsRegistered() {
        XCTAssertTrue(CLIModeDetector.recognizedCommands.contains("tickets"))
        XCTAssertTrue(CLIHelp.text.contains("whisperm8 tickets"))
        XCTAssertTrue(TicketsCLICommand.help.contains("tickets doctor"))
    }
}
