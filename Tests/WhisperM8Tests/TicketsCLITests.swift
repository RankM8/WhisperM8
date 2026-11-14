import XCTest
@testable import WhisperM8

final class TicketsCLITests: XCTestCase {
    // MARK: Umgebung

    private let jon = UUID(uuidString: "7493E390-EDEB-4CC0-AEBE-68EF61F356EE")!
    private let dex = UUID(uuidString: "840BFE4C-0000-4000-8000-000000000001")!
    private let ole = UUID(uuidString: "B0096DCA-0000-4000-8000-000000000002")!
    private let jarvis = UUID(uuidString: "A37D241B-0000-4000-8000-000000000003")!
    /// Chat des zweiten Projekts (Workspace `dealsupply`).
    private let kai = UUID(uuidString: "FA6FAE20-0000-4000-8000-000000000004")!
    private let giuliano = TicketPerson(id: "u1", name: "Giuliano Costa")
    private let project = "/Users/g/repos/whisperm8"
    private let otherProject = "/Users/g/repos/ListM8"

    private final class World {
        /// Quelle des Workspaces `whisperm8`.
        let source = TicketSourceStub()
        /// Quelle des zweiten Workspaces `dealsupply`.
        let other = TicketSourceStub()
        /// Welche Workspaces angesprochen wurden, in Reihenfolge.
        var asked: [String] = []
        var config = TicketConfig()
        var savedConfigs: [TicketConfig] = []
        var storedKeys: [String: String] = ["whisperm8": "lin_api_alt"]
        /// Geschriebene Keys als `workspace=key`.
        var writtenKeys: [String] = []
        var writeSucceeds = true
        var validation: Result<TicketAccount, TicketSourceError> =
            .success(TicketAccount(userName: "Giuliano Costa", workspace: "WhisperM8 (linear.app/whisperm8)", workspaceKey: "whisperm8", isAdmin: true))
        var chats: [TicketChat] = []
        var appReachable = true
        var caller: UUID?
        var directory = "/Users/g/repos/whisperm8"
        var stdin = ""
        var files: [String: String] = [:]
        var data: [String: Data] = [:]
        var existing: Set<String> = []
    }

    private func makeWorld() -> World {
        let world = World()
        world.config.set(team: "WM8", forProject: project)
        world.config.set(workspace: "whisperm8", forTeam: "WM8")
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
            source: { workspace in
                world.asked.append(workspace)
                return workspace == "dealsupply" ? world.other : world.source
            },
            config: { world.config },
            saveConfig: { world.config = $0; world.savedConfigs.append($0) },
            credential: TicketCredentialStore(
                read: { world.storedKeys[$0] },
                write: { workspace, key in
                    world.writtenKeys.append("\(workspace)=\(key)")
                    if world.writeSucceeds { world.storedKeys[workspace] = key }
                    return world.writeSucceeds
                },
                delete: { world.storedKeys[$0] = nil }),
            validateKey: { _ in world.validation },
            chats: { (world.chats, world.appReachable) },
            callerChatID: { world.caller },
            currentDirectory: { world.directory },
            readStdin: { world.stdin },
            readFile: { world.files[$0] },
            readData: { path, limit in world.data[path].flatMap { $0.count <= limit ? $0 : nil } },
            fileExists: { world.existing.contains($0) },
            now: { Date(timeIntervalSince1970: 1_794_000_000) }
        )
    }

    private func run(_ arguments: [String], _ world: World) async throws -> TicketsCLIRunner.Output {
        await TicketsCLIRunner.execute(try TicketsCLIArguments.parse(arguments), environment: environment(world),
                                       otherWorkspace: TicketsCLIArguments.allowsOtherWorkspace(arguments))
    }

    /// Zwei Firmen: `whisperm8` mit dem Team WM8, `dealsupply` mit dem Team DS.
    private func twoWorkspaceWorld() -> World {
        let world = makeWorld()
        world.config.set(team: "DS", forProject: otherProject)
        world.config.set(workspace: "dealsupply", forTeam: "DS")
        world.storedKeys["dealsupply"] = "lin_api_ds"
        world.other.onAccount = {
            TicketAccount(userName: "Giuliano Costa", workspace: "DealSupply (linear.app/dealsupply)", workspaceKey: "dealsupply", isAdmin: true)
        }
        world.other.onTeams = { ["DEA", "DS", "PRB"] }
        world.chats.append(TicketChat(id: kai, title: "Kai · Umzug", projectName: "ListM8", projectPath: otherProject,
                                      state: .idle, isRunning: true))
        world.other.onTicket = { key in
            var ticket = TicketFixtures.ticket(5, status: "Todo", title: "Import prüfen")
            ticket.key = key
            return TicketContext(ticket: ticket, team: "DS", statuses: TicketFixtures.statuses)
        }
        return world
    }

    private func context(_ ticket: Ticket) -> TicketContext {
        TicketContext(ticket: ticket, team: "WM8", statuses: TicketFixtures.statuses)
    }

    /// Schreibende Aufrufe, ohne die Lese-Aufrufe davor.
    private func writes(_ world: World, _ source: TicketSourceStub? = nil) -> [String] {
        (source ?? world.source).calls.filter { !$0.hasPrefix("ticket ") && !$0.hasPrefix("board ") && !$0.hasPrefix("person ") && $0 != "linked" && $0 != "account" }
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
        XCTAssertEqual(try TicketsCLIArguments.parse(["done", "WM8-12", "--no-summary", "--status", "Merge-bereit", "--note", "Branch steht."]),
                       .done(key: "WM8-12", chat: nil, status: "Merge-bereit", note: .literal("Branch steht."), force: false,
                             summary: { var summary = TicketsDoneSummary(); summary.skip = true; return summary }()))
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
            ["label", "WM8-1"], ["new", "Titel", "--priority", "sofort"], ["setup", "--project", "/x"], ["link", "WM8-1", "--chat"], ["setup", "--workspace"], ["setup", "--reassign"],
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
        let output = try await run(["done", "WM8-12", "--no-summary", "--status", "merge-bereit", "--note", "Branch steht."], world)
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
        let output = try await run(["done", "WM8-12", "--no-summary", "--status", "Fertig"], world)
        XCTAssertEqual(output.exitCode, TicketsCLIExit.notFound)
        XCTAssertTrue(output.stderr.contains("Möglich: Backlog, Todo, In Progress, Merge-bereit, Done, Canceled"))
        XCTAssertTrue(writes(world).isEmpty, "erst prüfen, dann schreiben")
    }

    func testDoneWithoutLinkOnlySetsStatus() async throws {
        let world = makeWorld()
        world.caller = jarvis
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12, status: "Merge-bereit")) }
        let output = try await run(["done", "WM8-12", "--no-summary", "--status", "Done", "--chat", "7493"], world)
        XCTAssertEqual(writes(world), ["setStatus id-12 s4"], "keine Verknüpfung anlegen, nur um sie zu beenden")
        XCTAssertTrue(output.stdout.contains("war nicht (mehr) verknüpft"), "nichts behaupten, was nicht passiert ist")
    }

    func testOnlyTheSupervisorCompletesATicket() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12, status: "In Progress", links: [TicketFixtures.link(self.jon)])) }

        // Arbeitender Chat: Absage, bevor irgendetwas geschrieben ist.
        let viaDone = try await run(["done", "WM8-12", "--no-summary", "--status", "Done"], world)
        XCTAssertEqual(viaDone.exitCode, TicketsCLIExit.conflict)
        XCTAssertTrue(viaDone.stderr.contains("setzt der Supervisor"), viaDone.stderr)
        let viaStatus = try await run(["status", "WM8-12", "Done"], world)
        XCTAssertEqual(viaStatus.exitCode, TicketsCLIExit.conflict)
        XCTAssertTrue(writes(world).isEmpty)

        // Abgeben darf er.
        _ = try await run(["done", "WM8-12", "--no-summary", "--status", "Merge-bereit"], world)
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
        _ = try await run(["done", "WM8-12", "--no-summary"], world)
        XCTAssertTrue(writes(world).isEmpty, "schon beendet: die Zeit der Verknüpfung bleibt")
    }

    func testDoneWithUnreadableNoteChangesNothing() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12, status: "In Progress", links: [TicketFixtures.link(self.jon)])) }
        let missing = try await run(["done", "WM8-12", "--no-summary", "--note", "@fehlt.md", "--status", "Merge-bereit"], world)
        XCTAssertEqual(missing.exitCode, TicketsCLIExit.usage)
        let blank = try await run(["done", "WM8-12", "--no-summary", "--note", "   "], world)
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

    // MARK: Abschluss, Entscheidung, Kästchen

    func testDoneAsksForASummary() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12, status: "In Progress", links: [TicketFixtures.link(self.jon)])) }
        let missing = try await run(["done", "WM8-12", "--status", "Merge-bereit"], world)
        XCTAssertEqual(missing.exitCode, TicketsCLIExit.usage)
        XCTAssertTrue(missing.stderr.contains("--built") && missing.stderr.contains("--no-summary"), missing.stderr)
        XCTAssertTrue(writes(world).isEmpty, "ohne Zusammenfassung wird nichts umgestellt")
        XCTAssertThrowsError(try TicketsCLIArguments.parse(["done", "WM8-12", "--no-summary", "--built", "x"]))
    }

    func testDoneWritesTheCompletionBeforeAnythingElse() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12, status: "In Progress", links: [TicketFixtures.link(self.jon)])) }
        let output = try await run(["done", "WM8-12", "--status", "Merge-bereit", "--built", "Schalter und Einstellungen",
                                    "--commit", "dfda8d7c", "--not", "die Ansicht", "--test", "Schalter an", "--test", "Key eintragen"], world)
        XCTAssertEqual(output.exitCode, 0, output.stderr)
        let calls = writes(world)
        XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(calls[0].hasPrefix("comment id-12 **Abschluss · "), calls[0])
        XCTAssertTrue(calls[0].contains("· 6 Jon**") && calls[0].contains("**Gebaut:** Schalter und Einstellungen"), calls[0])
        XCTAssertTrue(calls[0].contains("**Commit:** dfda8d7c") && calls[0].contains("**Nicht Teil davon:** die Ansicht"))
        XCTAssertTrue(calls[0].contains("- [ ] Schalter an\n- [ ] Key eintragen"))
        XCTAssertEqual(Array(calls[1...]), ["saveLink id-12 6 Jon beendet", "setStatus id-12 s3"])
        XCTAssertTrue(output.stdout.contains("Abschluss steht am Ticket"))
    }

    func testDoneUploadsAnImageOnlyIfItIsOne() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12, status: "In Progress", links: [TicketFixtures.link(self.jon)])) }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        world.data["bild.png"] = png + Data(repeating: 1, count: 1_992)
        world.data["gross.png"] = png + Data(repeating: 1, count: TicketImage.maxBytes)
        world.data["verlauf.jsonl"] = Data(repeating: 1, count: 10)
        world.data["getarnt.png"] = Data("kein Bild, nur die Endung".utf8)

        for bad in ["verlauf.jsonl", "gross.png", "fehlt.png", "getarnt.png"] {
            let output = try await run(["done", "WM8-12", "--built", "x", "--image", bad], world)
            XCTAssertEqual(output.exitCode, TicketsCLIExit.usage, bad)
        }
        XCTAssertTrue(writes(world).isEmpty, "nichts hochgeladen, nichts umgestellt")

        let output = try await run(["done", "WM8-12", "--built", "x", "--image", "bild.png"], world)
        XCTAssertEqual(output.exitCode, 0, output.stderr)
        let calls = writes(world)
        XCTAssertEqual(calls.first, "upload bild.png image/png 2000")
        XCTAssertTrue(calls[1].contains("![Bild](https://uploads.linear.app/test/bild.png)"), calls[1])
    }

    func testDoneSaysWhenTheCompletionIsWrittenButTheRestFailed() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12, status: "In Progress", links: [TicketFixtures.link(self.jon)])) }
        world.source.failWritesStartingWith = "saveLink"
        let output = try await run(["done", "WM8-12", "--built", "x", "--status", "Merge-bereit"], world)
        XCTAssertEqual(output.exitCode, TicketsCLIExit.unavailable)
        XCTAssertTrue(output.stderr.contains("Der Abschluss steht schon am Ticket") && output.stderr.contains("--no-summary"), output.stderr)
        XCTAssertEqual(writes(world).filter { $0.hasPrefix("comment") }.count, 1)
        XCTAssertFalse(writes(world).contains { $0.hasPrefix("setStatus") }, "nach dem Fehler wird nichts weiter umgestellt")
    }

    func testClosingAfterTheMergeNeedsNoSummary() async throws {
        let world = makeWorld()
        world.caller = jarvis
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12, status: "Merge-bereit", links: [TicketFixtures.link(self.jon, active: false)])) }
        let output = try await run(["done", "WM8-12", "--status", "Done", "--chat", "7493"], world)
        XCTAssertEqual(output.exitCode, 0, output.stderr)
        XCTAssertEqual(writes(world), ["setStatus id-12 s4"], "kein zweiter Abschluss vom Supervisor")
    }

    func testCompletionAsAWholeHasASizeLimit() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12, status: "In Progress")) }
        let step = String(repeating: "s", count: 20_000)
        let output = try await run(["done", "WM8-12", "--built", "x", "--test", step, "--test", step, "--test", step, "--test", step], world)
        XCTAssertEqual(output.exitCode, TicketsCLIExit.usage)
        XCTAssertTrue(output.stderr.contains("Abschluss zu lang"), output.stderr)
        XCTAssertTrue(writes(world).isEmpty)
    }

    func testDecideWritesTheFixedShape() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(81)) }
        world.source.onPerson = { _ in self.giuliano }
        let output = try await run(["decide", "WM8-81", "--question", "Wo lebt die Ansicht?", "--option", "Umschalter",
                                    "--option", "eigenes Fenster", "--chosen", "Umschalter"], world)
        XCTAssertEqual(output.exitCode, 0, output.stderr)
        let comment = try XCTUnwrap(writes(world).first)
        XCTAssertTrue(comment.hasPrefix("comment id-81 **Entscheidung · "))
        XCTAssertTrue(comment.contains("**Frage:** Wo lebt die Ansicht?"))
        XCTAssertTrue(comment.contains("**Möglichkeiten:**\n* Umschalter\n* eigenes Fenster"))
        XCTAssertTrue(comment.contains("**Gewählt:** Umschalter"))
        XCTAssertTrue(comment.hasSuffix("**Entschieden von:** Giuliano Costa"), "ohne --by die Person, der der Zugang gehört")

        let named = try await run(["decide", "WM8-81", "--question", "F", "--option", "a", "--option", "b", "--chosen", "a",
                                   "--by", "Richard"], world)
        XCTAssertTrue(named.stdout.contains("Richard"))
        for bad in [["decide", "WM8-81", "--question", "F", "--option", "a", "--chosen", "a"],
                    ["decide", "WM8-81", "--option", "a", "--option", "b", "--chosen", "a"],
                    ["decide", "WM8-81", "--question", "F", "--option", "a", "--option", "b"]] {
            XCTAssertThrowsError(try TicketsCLIArguments.parse(bad), "\(bad)")
        }
    }

    private let criteria = "**Stand:** x\n\n## Fertig, wenn\n\n- [ ] Board steht\n- [x] Karte zeigt den Chat\n- [ ] Detail da\n\n## Hinweise\nText"

    func testCheckListsAndTicksBoxes() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(81, description: self.criteria)) }
        let listed = try await run(["check", "WM8-81"], world)
        XCTAssertEqual(listed.stdout, "1  [ ] Board steht\n2  [x] Karte zeigt den Chat\n3  [ ] Detail da")
        XCTAssertTrue(writes(world).isEmpty, "anzeigen ändert nichts")

        let ticked = try await run(["check", "WM8-81", "1", "detail"], world)
        XCTAssertEqual(ticked.exitCode, 0, ticked.stderr)
        XCTAssertEqual(ticked.stdout, "WM8-81: 2 Kästchen abgehakt (3 von 3 erledigt).")
        let written = try XCTUnwrap(writes(world).first)
        XCTAssertTrue(written.contains("- [x] Board steht\n- [x] Karte zeigt den Chat\n- [x] Detail da"))
        XCTAssertTrue(written.contains("**Stand:** x") && written.hasSuffix("## Hinweise\nText"), "der Rest der Beschreibung bleibt")

        let reopened = try await run(["check", "WM8-81", "2", "--uncheck"], world)
        XCTAssertEqual(reopened.stdout, "WM8-81: 1 Kästchen wieder offen (0 von 3 erledigt).")

        let asJSON = await TicketsCLIRunner.execute(try TicketsCLIArguments.parse(["check", "WM8-81", "--json"]),
                                                    environment: environment(world), json: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(asJSON.stdout.utf8)) as? [String: Any])
        XCTAssertEqual((object["items"] as? [[String: Any]])?.map { $0["done"] as? Bool }, [false, true, false])
    }

    func testCheckRefusesWhatItCannotPlace() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(81, description: self.criteria)) }
        let missing = try await run(["check", "WM8-81", "9"], world)
        XCTAssertEqual(missing.exitCode, TicketsCLIExit.notFound)
        let ambiguous = try await run(["check", "WM8-81", "a"], world)
        XCTAssertEqual(ambiguous.exitCode, TicketsCLIExit.conflict)
        let unchanged = try await run(["check", "WM8-81", "2"], world)
        XCTAssertEqual(unchanged.exitCode, 0)
        XCTAssertTrue(unchanged.stdout.contains("nichts geändert"))
        XCTAssertTrue(writes(world).isEmpty)

        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(81, description: "ohne")) }
        let none = try await run(["check", "WM8-81", "1"], world)
        XCTAssertEqual(none.exitCode, TicketsCLIExit.notFound)
    }

    func testCriteriaProgressShowsInOutputs() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(81, description: self.criteria)) }
        world.source.onBoard = { _ in TicketFixtures.snapshot([TicketFixtures.ticket(81, status: "In Progress", description: self.criteria)]) }
        let shown = try await run(["show", "WM8-81"], world)
        XCTAssertTrue(shown.stdout.contains("Fertig, wenn: 1 von 3 abgehakt"), shown.stdout)
        let board = try await run(["board"], world)
        XCTAssertTrue(board.stdout.contains("In Progress 1/3"), board.stdout)
        let json = try await run(["board", "--json"], world)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        let ticket = try XCTUnwrap((object["tickets"] as? [[String: Any]])?.first)
        XCTAssertEqual(ticket["criteria"] as? [String: Int], ["done": 1, "total": 3])
    }

    func testStartedColumnGroupsByStatusOfTheTeam() async throws {
        let world = makeWorld()
        var waiting = TicketFixtures.ticket(3, title: "gemergt", priority: 1)
        waiting.status = TicketStatus(id: "s6", name: "Wartet aufs Ausliefern", kind: .started, position: 3.5)
        world.source.onBoard = { _ in
            TicketFixtures.snapshot([
                waiting,
                TicketFixtures.ticket(2, status: "Merge-bereit", title: "abgegeben", priority: 2),
                TicketFixtures.ticket(1, status: "In Progress", title: "läuft", priority: 4),
                TicketFixtures.ticket(4, status: "In Progress", title: "läuft dringend", priority: 1),
            ])
        }
        let output = try await run(["board"], world)
        let keys = output.stdout.split(separator: "\n").filter { $0.hasPrefix("  WM8-") }.map { String($0.dropFirst(2).prefix(5)) }
        XCTAssertEqual(keys, ["WM8-4", "WM8-1", "WM8-2", "WM8-3"],
                       "erst nach Status in der Reihenfolge des Teams, darin nach Priorität; „Wartet aufs Ausliefern“ ist nicht erledigt")
        XCTAssertTrue(output.stdout.contains("Wartet aufs Ausliefern"))
    }

    // MARK: Ordnung im Prüfbericht

    func testDoctorReportsHygieneAsHints() async throws {
        let world = makeWorld()
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        world.source.onBoard = { _ in
            TicketFixtures.snapshot([
                TicketFixtures.ticket(1, status: "In Progress", description: "## Fertig, wenn\n- [ ] x", updatedAt: now),
                TicketFixtures.ticket(2, status: "Todo", description: "", project: nil, updatedAt: now.addingTimeInterval(-30 * 86_400)),
            ])
        }
        let output = try await run(["doctor"], world)
        XCTAssertEqual(output.exitCode, 0, "Hinweise lassen den Bericht grün: \(output.stdout)")
        XCTAssertTrue(output.stdout.contains("ACHTE  Ordnung WM8    1 ohne Projekt: WM8-2"), output.stdout)
        XCTAssertTrue(output.stdout.contains("1 eingeplant oder in Arbeit, aber ohne „Fertig, wenn“: WM8-2"))
        XCTAssertTrue(output.stdout.contains("1 in Arbeit, aber nie hing ein Chat daran: WM8-1"))
        XCTAssertTrue(output.stdout.contains("1 seit über 3 Wochen unberührt: WM8-2"))
    }

    func testSetupAndDoctorCheckTheAreasTable() async throws {
        let world = makeWorld()
        world.source.onBoard = { _ in TicketFixtures.snapshot([]) }
        let table = "| Bereich | Ordner | Linear-Projekt |\n|---|---|---|\n| Diktat | `docs/features/dictation` | Diktat |\n| Tickets | `docs/features/tickets.md` | Tickets |"
        world.files[project + "/docs/features/tickets.md"] = table
        world.files[project + "/docs/ohne.md"] = "keine Tabelle"
        world.existing = [project + "/docs/features/dictation"]
        world.source.onProjects = { _ in ["Diktat", "Tickets", "Controller"] }

        let wrong = try await run(["setup", "--team", "WM8", "--project", project, "--areas", "docs/ohne.md"], world)
        XCTAssertEqual(wrong.exitCode, TicketsCLIExit.notFound)
        XCTAssertTrue(world.config.areasFileByProjectPath.isEmpty)
        XCTAssertThrowsError(try TicketsCLIArguments.parse(["setup", "--areas", "x.md"]), "braucht --project und --team")

        let set = try await run(["setup", "--team", "WM8", "--project", project, "--areas", "docs/features/tickets.md"], world)
        XCTAssertEqual(set.exitCode, 0, set.stderr)
        XCTAssertEqual(world.config.areasFileByProjectPath, [project: "docs/features/tickets.md"])

        let report = try await run(["doctor"], world)
        XCTAssertEqual(report.exitCode, 0)
        XCTAssertTrue(report.stdout.contains("ACHTE  Bereiche WM8   Projekt „Controller“ steht nicht in der Tabelle"), report.stdout)
        XCTAssertTrue(report.stdout.contains("Doku fehlt: docs/features/tickets.md (Tickets)"))
        XCTAssertFalse(report.stdout.contains("Doku fehlt: docs/features/dictation"))

        world.existing.insert(project + "/docs/features/tickets.md")
        world.source.onProjects = { _ in ["Diktat", "Tickets"] }
        let clean = try await run(["doctor"], world)
        XCTAssertTrue(clean.stdout.contains("ok     Bereiche WM8   2 Bereiche stimmen mit docs/features/tickets.md überein"), clean.stdout)
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
        XCTAssertEqual(world.writtenKeys, ["whisperm8=lin_api_neu"], "abgelegt unter dem Workspace, den Linear zum Key nennt")
        XCTAssertFalse(stored.stdout.contains("lin_api"), "der Key steht nie in der Ausgabe")

        world.validation = .failure(.unauthorized)
        world.stdin = "lin_api_falsch"
        let rejected = try await run(["setup", "--key-stdin"], world)
        XCTAssertEqual(rejected.exitCode, TicketsCLIExit.unavailable)
        XCTAssertEqual(world.writtenKeys, ["whisperm8=lin_api_neu"], "abgelehnter Key wird nicht gespeichert")
        XCTAssertEqual(world.storedKeys["whisperm8"], "lin_api_neu")

        world.stdin = "kein key mit \"zeichen\""
        let invalid = try await run(["setup", "--key-stdin"], world)
        XCTAssertEqual(invalid.exitCode, TicketsCLIExit.usage)
    }

    func testSetupProjectMappingResolvesRelativePaths() async throws {
        let world = makeWorld()
        world.config = TicketConfig()
        world.config.add(workspace: "dealsupply")
        world.other.onTeams = { ["DS"] }
        world.directory = "/Users/g/repos"
        let output = try await run(["setup", "--project", "ListM8", "--team", "ds"], world)
        XCTAssertEqual(world.savedConfigs.last?.teamsByProjectPath, ["/Users/g/repos/ListM8": "DS"])
        XCTAssertEqual(world.savedConfigs.last?.workspacesByTeam, ["DS": "dealsupply"])
        XCTAssertTrue(output.stdout.contains("/Users/g/repos/ListM8 gehört zum Team DS im Workspace „dealsupply“."), output.stdout)
    }

    // MARK: Mehrere Workspaces

    func testTicketNumberPicksTheWorkspace() async throws {
        let world = twoWorkspaceWorld()
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12)) }
        _ = try await run(["show", "WM8-12"], world)
        _ = try await run(["show", "DS-5"], world)
        XCTAssertEqual(world.asked, ["whisperm8", "dealsupply"], "jede Nummer geht an den Workspace ihres Teams")
        XCTAssertEqual(world.source.calls, ["ticket WM8-12"])
        XCTAssertEqual(world.other.calls, ["ticket DS-5"], "lesen über die Grenze geht")
    }

    func testNoWritingIntoTheOtherWorkspace() async throws {
        let world = twoWorkspaceWorld()
        // Der Aufrufer steht im WhisperM8-Projekt (auch in einem Arbeitsordner darunter).
        world.directory = project + "/.claude/worktrees/ticket-board"
        let commands: [[String]] = [
            ["link", "DS-5"], ["done", "DS-5", "--no-summary", "--status", "Merge-bereit"], ["unlink", "DS-5"], ["status", "DS-5", "Todo"],
            ["note", "DS-5", "Stand"], ["comment", "DS-5", "Text"], ["assign", "DS-5", "me"], ["label", "DS-5", "--add", "Bug"],
            ["new", "Titel", "--team", "DS"], ["check", "DS-5", "1"],
            ["decide", "DS-5", "--question", "F", "--option", "a", "--option", "b", "--chosen", "a"],
            ["done", "DS-5", "--built", "x", "--image", "bild.png"],
        ]
        for command in commands {
            let output = try await run(command, world)
            XCTAssertEqual(output.exitCode, TicketsCLIExit.conflict, "\(command)")
            XCTAssertTrue(output.stderr.contains("„dealsupply“") && output.stderr.contains("„whisperm8“"), output.stderr)
            XCTAssertTrue(output.stderr.contains("--other-workspace"))
        }
        XCTAssertTrue(world.other.calls.isEmpty, "die fremde Quelle wird nicht einmal gefragt: \(world.other.calls)")
        XCTAssertTrue(world.asked.isEmpty)

        // Umgekehrt genauso: aus dem anderen Projekt nicht ins WM8-Team.
        world.directory = otherProject
        world.caller = kai
        let back = try await run(["comment", "WM8-12", "Text"], world)
        XCTAssertEqual(back.exitCode, TicketsCLIExit.conflict)
        XCTAssertTrue(world.source.calls.isEmpty)
    }

    func testTheChatsProjectCountsNotTheFolderOfItsShell() async throws {
        let world = twoWorkspaceWorld()
        // Chat des WhisperM8-Projekts, Shell irgendwo: außerhalb jedes Projekts oder im Ordner des anderen.
        for directory in ["/tmp", "/Users/g", otherProject, "/Users/g/repos/whisperm8-kopie"] {
            world.directory = directory
            let output = try await run(["comment", "DS-5", "Text"], world)
            XCTAssertEqual(output.exitCode, TicketsCLIExit.conflict, directory)
            XCTAssertTrue(output.stderr.contains("dieser Chat (Projekt whisperm8) gehört zu „whisperm8“"), output.stderr)
        }
        XCTAssertTrue(world.other.calls.isEmpty)

        // Sein eigenes Team erreicht er von überall.
        world.directory = otherProject
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12)) }
        let own = try await run(["comment", "WM8-12", "Text"], world)
        XCTAssertEqual(own.exitCode, 0, own.stderr)

        // Ein Chat, dessen Projekt keinem Workspace zugeordnet ist: Der Ordner entscheidet.
        let loose = UUID()
        world.chats.append(TicketChat(id: loose, title: "Ida · Sonstiges", projectName: "anderes", projectPath: "/Users/g/repos/anderes",
                                      state: .idle, isRunning: true))
        world.caller = loose
        world.directory = project
        let fallback = try await run(["comment", "DS-5", "Text"], world)
        XCTAssertEqual(fallback.exitCode, TicketsCLIExit.conflict)
        XCTAssertTrue(fallback.stderr.contains("dieser Ordner gehört zu „whisperm8“"), fallback.stderr)
    }

    func testWritingInTheOwnWorkspaceAndWithExplicitFlag() async throws {
        let world = twoWorkspaceWorld()
        world.directory = otherProject
        world.caller = kai
        let own = try await run(["comment", "DS-5", "Text"], world)
        XCTAssertEqual(own.exitCode, 0, own.stderr)
        XCTAssertEqual(writes(world, world.other), ["comment id-5 Text"])

        world.directory = project
        world.caller = jon
        let forced = try await run(["comment", "DS-5", "Text", "--other-workspace"], world)
        XCTAssertEqual(forced.exitCode, 0, forced.stderr)
        XCTAssertEqual(writes(world, world.other).count, 2, "nur mit dem ausdrücklichen Schalter")
        XCTAssertTrue(world.source.calls.isEmpty, "der eigene Workspace bleibt unberührt")
        XCTAssertFalse(TicketsCLIArguments.allowsOtherWorkspace(["comment", "DS-5", "--", "--other-workspace"]), "hinter -- ist es Text")

        // Außerhalb jedes Projekts (Mensch im Terminal) gibt es keine Grenze.
        world.directory = "/Users/g"
        world.caller = nil
        let outside = try await run(["comment", "DS-5", "Text"], world)
        XCTAssertEqual(outside.exitCode, 0, outside.stderr)
    }

    func testChatOfOneProjectDoesNotHangOnTicketsOfTheOther() async throws {
        let world = twoWorkspaceWorld()
        // Aus dem Terminal, ohne Projektgrenze für den Aufrufer: Der Chat selbst gehört zu WhisperM8.
        world.directory = "/Users/g"
        world.caller = nil
        let output = try await run(["link", "DS-5", "--chat", "840b"], world)
        XCTAssertEqual(output.exitCode, TicketsCLIExit.conflict)
        XCTAssertTrue(output.stderr.contains("Dex") && output.stderr.contains("„dealsupply“"), output.stderr)
        XCTAssertTrue(world.other.calls.isEmpty)
    }

    func testUnmappedTeamIsNeverGuessed() async throws {
        let world = twoWorkspaceWorld()
        let output = try await run(["show", "PRB-1"], world)
        XCTAssertEqual(output.exitCode, TicketsCLIExit.usage)
        XCTAssertTrue(output.stderr.contains("tickets setup --team PRB"), output.stderr)
        XCTAssertTrue(world.asked.isEmpty, "bei zwei Workspaces wird nicht geraten")

        // Mit nur einem Workspace liegt jedes Team dort.
        let single = makeWorld()
        single.source.onTicket = { _ in self.context(TicketFixtures.ticket(1)) }
        let found = try await run(["show", "ABC-1"], single)
        XCTAssertEqual(found.exitCode, 0, found.stderr)
        XCTAssertEqual(single.asked, ["whisperm8"])
    }

    func testMineAsksEveryWorkspace() async throws {
        let world = twoWorkspaceWorld()
        world.source.onLinked = { _ in [TicketFixtures.ticket(23, links: [TicketFixtures.link(self.jon)])] }
        world.other.onLinked = { _ in
            var ticket = TicketFixtures.ticket(5, links: [TicketFixtures.link(self.jon, active: false)])
            ticket.key = "DS-5"
            return [ticket]
        }
        let output = try await run(["mine"], world)
        XCTAssertEqual(output.exitCode, 0, output.stderr)
        XCTAssertTrue(output.stdout.contains("WM8-23") && output.stdout.contains("DS-5"), output.stdout)
        XCTAssertEqual(Set(world.asked), ["whisperm8", "dealsupply"])
    }

    func testSetupStoresTheKeyUnderItsOwnWorkspace() async throws {
        let world = makeWorld()
        world.validation = .success(TicketAccount(userName: "Giuliano Costa", workspace: "DealSupply (linear.app/dealsupply)",
                                                  workspaceKey: "dealsupply", isAdmin: true))
        world.stdin = "lin_api_ds"
        let wrong = try await run(["setup", "--key-stdin", "--workspace", "whisperm8"], world)
        XCTAssertEqual(wrong.exitCode, TicketsCLIExit.conflict, "ein Key lässt sich nicht unter dem falschen Workspace ablegen")
        XCTAssertTrue(world.writtenKeys.isEmpty)
        XCTAssertEqual(world.storedKeys, ["whisperm8": "lin_api_alt"])

        let stored = try await run(["setup", "--key-stdin"], world)
        XCTAssertEqual(stored.exitCode, 0, stored.stderr)
        XCTAssertEqual(world.storedKeys, ["whisperm8": "lin_api_alt", "dealsupply": "lin_api_ds"], "der andere Key bleibt, wie er ist")
        XCTAssertEqual(world.config.knownWorkspaces, ["dealsupply", "whisperm8"])
        XCTAssertFalse(stored.stdout.contains("lin_api"))
    }

    func testSetupFindsTheWorkspaceOfATeam() async throws {
        let world = twoWorkspaceWorld()
        let found = try await run(["setup", "--team", "prb"], world)
        XCTAssertEqual(found.exitCode, 0, found.stderr)
        XCTAssertEqual(world.config.workspacesByTeam["PRB"], "dealsupply")
        XCTAssertNil(world.config.teamsByProjectPath.values.first { $0 == "PRB" }, "ohne --project nur das Team")

        let missing = try await run(["setup", "--team", "XYZ"], world)
        XCTAssertEqual(missing.exitCode, TicketsCLIExit.notFound)

        world.source.onTeams = { ["WM8", "DEA"] }
        let twice = try await run(["setup", "--team", "DEA"], world)
        XCTAssertEqual(twice.exitCode, TicketsCLIExit.conflict, "gibt es das Kürzel in beiden, muss der Nutzer wählen")
        XCTAssertNil(world.config.workspacesByTeam["DEA"])
        let chosen = try await run(["setup", "--team", "DEA", "--workspace", "dealsupply"], world)
        XCTAssertEqual(chosen.exitCode, 0, chosen.stderr)
        XCTAssertEqual(world.config.workspacesByTeam["DEA"], "dealsupply")

        let notThere = try await run(["setup", "--team", "DS", "--workspace", "whisperm8"], world)
        XCTAssertEqual(notThere.exitCode, TicketsCLIExit.notFound, "ein Team wird nur einem Workspace zugeordnet, in dem es das Team gibt")
        XCTAssertEqual(world.config.workspacesByTeam["DS"], "dealsupply")
    }

    func testSetupDoesNotSilentlyMoveATeamToAnotherWorkspace() async throws {
        let world = twoWorkspaceWorld()
        world.other.onTeams = { ["DS", "WM8"] }   // dasselbe Kürzel gibt es auch drüben
        let saved = world.savedConfigs.count
        let refused = try await run(["setup", "--team", "WM8", "--workspace", "dealsupply"], world)
        XCTAssertEqual(refused.exitCode, TicketsCLIExit.conflict)
        XCTAssertTrue(refused.stderr.contains("schon dem Workspace „whisperm8“ zugeordnet") && refused.stderr.contains("--reassign"), refused.stderr)
        XCTAssertEqual(world.config.workspacesByTeam["WM8"], "whisperm8", "die Zuordnung bleibt, sonst schriebe das Projekt nach drüben")
        XCTAssertEqual(world.savedConfigs.count, saved, "nichts gespeichert")

        // Dieselbe Zuordnung noch einmal ist kein Umhängen.
        let same = try await run(["setup", "--team", "WM8", "--workspace", "whisperm8"], world)
        XCTAssertEqual(same.exitCode, 0, same.stderr)

        let moved = try await run(["setup", "--team", "WM8", "--workspace", "dealsupply", "--reassign"], world)
        XCTAssertEqual(moved.exitCode, 0, moved.stderr)
        XCTAssertEqual(world.config.workspacesByTeam["WM8"], "dealsupply")
        XCTAssertThrowsError(try TicketsCLIArguments.parse(["setup", "--reassign"]))
    }

    func testDoctorNamesATeamKeyThatExistsInTwoWorkspaces() async throws {
        let world = twoWorkspaceWorld()
        world.source.onBoard = { _ in TicketFixtures.snapshot([]) }
        world.other.onBoard = { _ in TicketFixtures.snapshot([]) }
        world.other.onTeams = { ["DS", "WM8"] }
        let output = try await run(["doctor"], world)
        XCTAssertEqual(output.exitCode, 0, "ein Hinweis, kein Fehler: \(output.stdout)")
        XCTAssertTrue(output.stdout.contains("ACHTE  Kürzel WM8     gibt es in dealsupply und whisperm8; erreichbar ist nur „whisperm8“"), output.stdout)
        XCTAssertFalse(output.stdout.contains("Kürzel DS"))
        let json = try await run(["doctor", "--json"], world)
        let checks = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [[String: Any]])
        XCTAssertEqual(checks.first { $0["name"] as? String == "Kürzel WM8" }?["warning"] as? Bool, true)
    }

    func testTextThatIsTooLongIsNotSent() async throws {
        let world = makeWorld()
        world.source.onTicket = { _ in self.context(TicketFixtures.ticket(12)) }
        world.files["gross.log"] = String(repeating: "a", count: TicketsText.maxBytes + 1)
        world.files["passt.md"] = String(repeating: "ä", count: TicketsText.maxBytes / 2)
        for command in [["comment", "WM8-12", "@gross.log"], ["note", "WM8-12", "@gross.log"], ["done", "WM8-12", "--no-summary", "--note", "@gross.log"],
                        ["new", "Titel", "--description", "@gross.log"]] {
            let output = try await run(command, world)
            XCTAssertEqual(output.exitCode, TicketsCLIExit.usage, "\(command)")
            XCTAssertTrue(output.stderr.contains("Text zu lang"), output.stderr)
        }
        world.stdin = String(repeating: "b", count: TicketsText.maxBytes + 1)
        let piped = try await run(["comment", "WM8-12", "-"], world)
        XCTAssertEqual(piped.exitCode, TicketsCLIExit.usage)
        XCTAssertTrue(writes(world).isEmpty, "nichts geht an das Ticket-System: \(writes(world))")

        let fits = try await run(["comment", "WM8-12", "@passt.md"], world)
        XCTAssertEqual(fits.exitCode, 0, "gezählt werden Bytes, genau an der Grenze geht es: \(fits.stderr)")
    }

    func testSetupAdoptsAKeyThatIsAlreadyInTheKeychain() async throws {
        let world = makeWorld()
        world.config = TicketConfig()
        let missing = try await run(["setup", "--workspace", "dealsupply"], world)
        XCTAssertEqual(missing.exitCode, TicketsCLIExit.unavailable, "ohne Key nichts zu übernehmen")

        let adopted = try await run(["setup", "--team", "WM8", "--project", project, "--workspace", "whisperm8"], world)
        XCTAssertEqual(adopted.exitCode, 0, adopted.stderr)
        XCTAssertEqual(world.config.knownWorkspaces, ["whisperm8"])
        XCTAssertEqual(world.config.workspace(forDirectory: project + "/Tests"), "whisperm8")

        // Liegt unter dem Namen der Key eines anderen Workspaces, wird nichts übernommen.
        world.storedKeys["dealsupply"] = "lin_api_falsch_abgelegt"
        let mismatch = try await run(["setup", "--workspace", "dealsupply"], world)
        XCTAssertEqual(mismatch.exitCode, TicketsCLIExit.conflict, mismatch.stderr)
        XCTAssertEqual(world.config.knownWorkspaces, ["whisperm8"])

        let invalid = try await run(["setup", "--workspace", "Deal Supply\""], world)
        XCTAssertEqual(invalid.exitCode, TicketsCLIExit.usage)
    }

    func testDoctorChecksEveryWorkspace() async throws {
        let world = twoWorkspaceWorld()
        world.source.onBoard = { _ in TicketFixtures.snapshot([TicketFixtures.ticket(1)]) }
        world.other.onBoard = { _ in TicketFixtures.snapshot([]) }
        let healthy = try await run(["doctor"], world)
        XCTAssertEqual(healthy.exitCode, 0, healthy.stdout)
        XCTAssertTrue(healthy.stdout.contains("DealSupply (linear.app/dealsupply)") && healthy.stdout.contains("WhisperM8 (linear.app/whisperm8)"))
        XCTAssertTrue(healthy.stdout.contains("(dealsupply)") && healthy.stdout.contains("(whisperm8)"), healthy.stdout)

        // Ein Key unter dem falschen Namen würde in der falschen Firma schreiben.
        world.other.onAccount = {
            TicketAccount(userName: "Giuliano Costa", workspace: "WhisperM8 (linear.app/whisperm8)", workspaceKey: "whisperm8", isAdmin: true)
        }
        let swapped = try await run(["doctor"], world)
        XCTAssertEqual(swapped.exitCode, TicketsCLIExit.unavailable)
        XCTAssertTrue(swapped.stdout.contains("dealsupply: der hinterlegte Key gehört zu WhisperM8"), swapped.stdout)
        XCTAssertFalse(swapped.stdout.contains("Team DS"), "ohne brauchbaren Zugang wird das Team nicht abgefragt")

        world.storedKeys["dealsupply"] = nil
        let noKey = try await run(["doctor"], world)
        XCTAssertTrue(noKey.stdout.contains("FEHLER Linear-Key     dealsupply: fehlt"), noKey.stdout)
        XCTAssertTrue(noKey.stdout.contains("ok     Team WM8"), "der andere Workspace läuft weiter")
    }

    func testAccessErrorsNameTheWorkspace() async throws {
        let world = twoWorkspaceWorld()
        world.other.onTicket = { _ in throw TicketSourceError.unauthorized }
        let output = try await run(["show", "DS-5"], world)
        XCTAssertEqual(output.exitCode, TicketsCLIExit.unavailable)
        XCTAssertEqual(output.stderr, TicketSourceError.unauthorized.message + " Betroffen: Workspace „dealsupply“.")
    }

    func testDoctor() async throws {
        let world = boardWorld()
        let healthy = try await run(["doctor"], world)
        XCTAssertEqual(healthy.exitCode, 0)
        XCTAssertTrue(healthy.stdout.contains("ok     Team WM8       4 offene Tickets, 2 mit Agent"), healthy.stdout)

        world.storedKeys = [:]
        let noKey = try await run(["doctor"], world)
        XCTAssertEqual(noKey.exitCode, TicketsCLIExit.unavailable)
        XCTAssertTrue(noKey.stdout.contains("FEHLER Linear-Key"), "der Bericht steht auf stdout, der Exit-Code zeigt das Problem")

        let asJSON = try await run(["doctor", "--json"], world)
        XCTAssertEqual(asJSON.exitCode, TicketsCLIExit.unavailable)
        let checks = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(asJSON.stdout.utf8)) as? [[String: Any]])
        XCTAssertEqual(checks.first?["ok"] as? Bool, false, "auch im Fehlerfall lesbares JSON auf stdout")

        world.storedKeys = ["whisperm8": "lin_api_alt"]
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
            let named = error == .notConfigured || error == .unauthorized
            XCTAssertEqual(output.stderr, error.message + (named ? " Betroffen: Workspace „whisperm8“." : ""))
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
