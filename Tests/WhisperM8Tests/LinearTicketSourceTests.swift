import XCTest
@testable import WhisperM8

final class LinearTicketSourceTests: XCTestCase {
    // MARK: Helfer

    /// Antwortet je Anfrage aus einer Liste von (Stichwort im Anfragetext → Antwort)
    /// und merkt sich, was gesendet wurde.
    private final class Stub: @unchecked Sendable {
        var requests: [(query: String, variables: [String: Any], authorization: String?)] = []
        var replies: [(needle: String, status: Int, body: String)] = []
        var failure: Error?

        func client(key: String? = "lin_api_test") -> LinearGraphQLClient {
            LinearGraphQLClient(apiKey: { key }, transport: { [self] request in
                if let failure { throw failure }
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
                let query = body["query"] as? String ?? ""
                requests.append((query, body["variables"] as? [String: Any] ?? [:], request.value(forHTTPHeaderField: "Authorization")))
                guard let reply = replies.first(where: { query.contains($0.needle) }) else {
                    return (Data(#"{"data":{}}"#.utf8), 200)
                }
                return (Data(reply.body.utf8), reply.status)
            })
        }
    }

    private let chatID = UUID(uuidString: "7493E390-EDEB-4CC0-AEBE-68EF61F356EE")!

    private func issueJSON(_ key: String, state: String, type: String, extra: String = "") -> String {
        """
        {"id":"id-\(key)","identifier":"\(key)","title":"Titel \(key)","description":"**Stand 14.11.2026:** offen.","priority":2,
         "url":"https://linear.app/x/issue/\(key)","state":{"id":"st-\(type)","name":"\(state)","type":"\(type)","position":2},
         "project":{"name":"Neustart"},"projectMilestone":{"name":"Erster echter Lauf"},
         "assignee":{"id":"u1","name":"Giuliano Costa"},"labels":{"nodes":[{"name":"Handtest"}]}\(extra)}
        """
    }

    private var ourAttachment: String {
        """
        ,"attachments":{"nodes":[
          {"id":"att1","title":"Chat: 6 Jon","subtitle":"arbeitet seit 14.11. 00:51 · WhisperM8 · whisperm8",
           "url":"whisperm8://chat/7493E390-EDEB-4CC0-AEBE-68EF61F356EE","metadata":{"source":"whisperm8","chatId":"7493E390-EDEB-4CC0-AEBE-68EF61F356EE"},
           "creator":{"name":"Giuliano Costa"}},
          {"id":"att2","title":"PR 12","subtitle":"offen","url":"https://github.com/x/y/pull/12","metadata":{}},
          {"id":"att3","title":"Chat: fremd","subtitle":"arbeitet","url":"whisperm8://chat/7493E390-EDEB-4CC0-AEBE-68EF61F356EE","metadata":{"source":"jemand"}}
        ]}
        """
    }

    // MARK: Lesen

    func testBoardMapsOpenAndClosedTickets() async throws {
        let stub = Stub()
        let blocked = #","inverseRelations":{"nodes":[{"type":"blocks","issue":{"state":{"type":"started"}}},{"type":"related","issue":{"state":{"type":"started"}}}]}"#
        let unblocked = #","inverseRelations":{"nodes":[{"type":"blocks","issue":{"state":{"type":"completed"}}}]}"#
        stub.replies = [
            ("closed: issues", 200, """
            {"data":{"teams":{"nodes":[{"id":"t1","key":"WM8","states":{"nodes":[
              {"id":"s4","name":"Done","type":"completed","position":3},{"id":"s2","name":"In Progress","type":"started","position":2},
              {"id":"s3","name":"Merge-bereit","type":"started","position":2.5},{"id":"s9","name":"Duplicate","type":"duplicate","position":5}]}}]},
              "closed":{"nodes":[\(issueJSON("WM8-29", state: "Done", type: "completed", extra: ourAttachment))]}}}
            """),
            ("pageInfo", 200, """
            {"data":{"issues":{"nodes":[\(issueJSON("WM8-23", state: "In Progress", type: "started", extra: ourAttachment + blocked)),
              \(issueJSON("WM8-13", state: "Backlog", type: "backlog", extra: unblocked))],
              "pageInfo":{"hasNextPage":false,"endCursor":null}}}}
            """),
        ]
        let fixed = Date(timeIntervalSince1970: 1_000)
        let snapshot = try await LinearTicketSource(client: stub.client(), now: { fixed }).board(team: "WM8")

        XCTAssertEqual(snapshot.fetchedAt, fixed)
        XCTAssertEqual(snapshot.statuses.map(\.name), ["In Progress", "Merge-bereit", "Done", "Duplicate"], "nach Art, dann Position")
        XCTAssertEqual(snapshot.statuses.last?.kind, .canceled, "duplicate zählt als verworfen")
        XCTAssertEqual(snapshot.tickets.map(\.key), ["WM8-29", "WM8-23", "WM8-13"])

        let open = snapshot.tickets[1]
        XCTAssertEqual(open.title, "Titel WM8-23")
        XCTAssertEqual(open.priority, 2)
        XCTAssertEqual(open.status, TicketStatus(id: "st-started", name: "In Progress", kind: .started, position: 2))
        XCTAssertEqual(open.project, "Neustart")
        XCTAssertEqual(open.milestone, "Erster echter Lauf")
        XCTAssertEqual(open.assignee, TicketPerson(id: "u1", name: "Giuliano Costa"))
        XCTAssertEqual(open.labels, ["Handtest"])
        XCTAssertTrue(open.isBlocked)
        XCTAssertFalse(snapshot.tickets[2].isBlocked, "blockierendes Ticket ist erledigt")
        XCTAssertEqual(open.links.map(\.id), ["att1"], "nur Anhänge mit unserer Adresse UND unserer Marke")
        XCTAssertEqual(open.links.first?.chatID, chatID)
        XCTAssertEqual(open.links.first?.isActive, true)
        XCTAssertEqual(open.links.first?.creatorName, "Giuliano Costa")

        XCTAssertEqual(stub.requests.first?.authorization, "lin_api_test", "persönlicher Key ohne Bearer")
        XCTAssertEqual(stub.requests.first?.variables["team"] as? String, "WM8")
    }

    func testBoardFollowsPagesAndStopsAtLimit() async throws {
        let stub = Stub()
        stub.replies = [
            ("closed: issues", 200, #"{"data":{"teams":{"nodes":[{"id":"t1","key":"WM8","states":{"nodes":[]}}]},"closed":{"nodes":[]}}}"#),
            ("pageInfo", 200, """
            {"data":{"issues":{"nodes":[\(issueJSON("WM8-1", state: "Todo", type: "unstarted"))],"pageInfo":{"hasNextPage":true,"endCursor":"c1"}}}}
            """),
        ]
        var source = LinearTicketSource(client: stub.client())
        source.maxPages = 3
        let snapshot = try await source.board(team: "WM8")
        XCTAssertEqual(snapshot.tickets.count, 3, "drei Seiten, dann Schluss")
        XCTAssertEqual(stub.requests.last?.variables["after"] as? String, "c1")
    }

    func testBoardUnknownTeam() async {
        let stub = Stub()
        stub.replies = [("closed: issues", 200, #"{"data":{"teams":{"nodes":[]},"closed":{"nodes":[]}}}"#)]
        await assertThrows(.notFound("Team XX")) { _ = try await LinearTicketSource(client: stub.client()).board(team: "XX") }
    }

    func testTicketContextAndStatusLookup() async throws {
        let stub = Stub()
        let team = #","team":{"key":"WM8","states":{"nodes":[{"id":"s1","name":"Todo","type":"unstarted","position":1},{"id":"s2","name":"In Progress","type":"started","position":2},{"id":"s3","name":"Merge-bereit","type":"started","position":2.5},{"id":"s4","name":"Done","type":"completed","position":3}]}}"#
        stub.replies = [("issue(id:", 200, #"{"data":{"issue":"# + issueJSON("WM8-23", state: "In Progress", type: "started", extra: team) + "}}")]
        let context = try await LinearTicketSource(client: stub.client()).ticket(key: "WM8-23")
        XCTAssertEqual(context.team, "WM8")
        XCTAssertEqual(context.status(named: "merge-bereit")?.id, "s3")
        XCTAssertEqual(context.status(named: "started")?.id, "s2", "Art statt Name: der erste Status dieser Art")
        XCTAssertEqual(context.firstStatus(of: .completed)?.id, "s4")
        XCTAssertNil(context.status(named: "gibt es nicht"))
    }

    // MARK: Schreiben

    func testSaveLinkSendsTheSharedFormat() async throws {
        let stub = Stub()
        let chat = TicketChat(id: chatID, title: "6 Jon · WM8-23 Linear", projectName: "whisperm8", projectPath: "/r", state: .working, isRunning: true)
        let source = LinearTicketSource(client: stub.client())
        try await source.saveLink(ticketID: "id-1", chat: chat, active: true, at: Date(timeIntervalSince1970: 0))
        try await source.saveLink(ticketID: "id-1", chat: chat, active: false, at: Date(timeIntervalSince1970: 0))

        let first = try XCTUnwrap(stub.requests.first?.variables["in"] as? [String: Any])
        XCTAssertEqual(first["issueId"] as? String, "id-1")
        XCTAssertEqual(first["url"] as? String, "whisperm8://chat/7493E390-EDEB-4CC0-AEBE-68EF61F356EE")
        XCTAssertEqual(first["title"] as? String, "Chat: 6 Jon · WM8-23 Linear")
        XCTAssertTrue((first["subtitle"] as? String ?? "").hasPrefix("arbeitet seit "))
        XCTAssertEqual((first["metadata"] as? [String: Any])?["source"] as? String, "whisperm8")
        XCTAssertEqual((first["metadata"] as? [String: Any])?["active"] as? Bool, true)
        let second = try XCTUnwrap(stub.requests.last?.variables["in"] as? [String: Any])
        XCTAssertTrue((second["subtitle"] as? String ?? "").hasPrefix("beendet am "))
        XCTAssertEqual(second["url"] as? String, first["url"] as? String, "dieselbe Adresse: Linear frischt den Anhang auf")
    }

    func testUnassignSendsNull() async throws {
        let stub = Stub()
        try await LinearTicketSource(client: stub.client()).assign(ticketID: "id-1", personID: nil)
        let input = try XCTUnwrap(stub.requests.first?.variables["in"] as? [String: Any])
        XCTAssertTrue(input["assigneeId"] is NSNull)
    }

    func testCreateResolvesNamesAndRejectsUnknown() async throws {
        let stub = Stub()
        let lookup = """
        {"data":{"teams":{"nodes":[{"id":"t1","states":{"nodes":[{"id":"s1","name":"Todo","type":"unstarted","position":1}]},
          "labels":{"nodes":[{"id":"l1","name":"Handtest"}]},"projects":{"nodes":[{"id":"p1","name":"Neustart ohne Chatverlust"}]}}]},
          "issueLabels":{"nodes":[{"id":"l9","name":"Bug"}]}}}
        """
        stub.replies = [
            ("issueLabels", 200, lookup),
            ("issueCreate", 200, #"{"data":{"issueCreate":{"issue":"# + issueJSON("WM8-70", state: "Todo", type: "unstarted") + "}}}"),
        ]
        let source = LinearTicketSource(client: stub.client())
        let draft = TicketDraft(team: "WM8", title: "Neu", description: "Text", project: "neustart ohne chatverlust",
                                statusName: "todo", priority: 2, labels: ["handtest", "Bug"], assigneeID: "u1")
        let created = try await source.create(draft)
        XCTAssertEqual(created.key, "WM8-70")
        let input = try XCTUnwrap(stub.requests.last?.variables["in"] as? [String: Any])
        XCTAssertEqual(input["teamId"] as? String, "t1")
        XCTAssertEqual(input["stateId"] as? String, "s1")
        XCTAssertEqual(input["projectId"] as? String, "p1")
        XCTAssertEqual(input["labelIds"] as? [String], ["l1", "l9"], "Team-Labels und Workspace-Labels")
        XCTAssertEqual(input["priority"] as? Int, 2)

        var wrong = draft
        wrong.statusName = "Gibt es nicht"
        await assertThrows(.notFound("Status „Gibt es nicht“")) { _ = try await source.create(wrong) }
    }

    func testPersonLookup() async throws {
        let stub = Stub()
        stub.replies = [
            ("viewer", 200, #"{"data":{"viewer":{"id":"u1","name":"Giuliano Costa"}}}"#),
            ("users(", 200, #"{"data":{"users":{"nodes":[{"id":"u2","name":"Xeno Suter","app":false},{"id":"u3","name":"Xenia Muster","app":false},{"id":"b1","name":"Xen Bot","app":true}]}}}"#),
        ]
        let source = LinearTicketSource(client: stub.client())
        let me = try await source.person(matching: "me")
        XCTAssertEqual(me.id, "u1")
        await assertThrows(.ambiguous("„xen“ passt auf mehrere Personen: Xenia Muster, Xeno Suter")) {
            _ = try await source.person(matching: "xen")
        }
        let exact = try await source.person(matching: "xeno suter")
        XCTAssertEqual(exact.id, "u2", "ein exakter Name gewinnt gegen ähnliche")
        XCTAssertFalse(stub.requests.last?.query.contains("id: { eq") ?? true, "kein ID-Filter für einen Namen")
        _ = try? await source.person(matching: "48801964-D507-4366-9864-492723DA01AB")
        XCTAssertTrue(stub.requests.last?.query.contains("id: { eq: $q }") ?? false, "eine ID wird auch als ID gesucht")
    }

    // MARK: Fehler

    func testNoKeyIsNotConfiguredWithoutRequest() async {
        let stub = Stub()
        await assertThrows(.notConfigured) { _ = try await stub.client(key: nil).run("{ viewer { id } }") }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testErrorMapping() async {
        let cases: [(Int, String, TicketSourceError)] = [
            (401, #"{"errors":[{"message":"Authentication required, not authenticated","extensions":{"code":"AUTHENTICATION_ERROR"}}]}"#, .unauthorized),
            (400, #"{"errors":[{"message":"Entity not found: Issue","extensions":{"code":"INPUT_ERROR","userPresentableMessage":"Could not find referenced Issue."}}]}"#, .notFound("Issue")),
            (400, #"{"errors":[{"message":"x","extensions":{"code":"RATELIMITED"}}]}"#, .rateLimited),
            (400, #"{"errors":[{"message":"intern","extensions":{"code":"INPUT_ERROR","userPresentableMessage":"Status passt nicht zum Team."}}]}"#, .rejected("Status passt nicht zum Team.")),
            (502, "<html>Bad Gateway</html>", .invalidResponse("HTTP 502")),
            (401, "nicht angemeldet", .unauthorized),
        ]
        for (status, body, expected) in cases {
            let stub = Stub()
            stub.replies = [("viewer", status, body)]
            await assertThrows(expected) { _ = try await stub.client().run("{ viewer { id } }") }
        }
    }

    func testNetworkFailure() async {
        let stub = Stub()
        stub.failure = URLError(.notConnectedToInternet)
        await assertThrows(.network("-1009")) { _ = try await stub.client().run("{ viewer { id } }") }
    }

    func testCancellationIsNotANetworkError() async {
        let stub = Stub()
        stub.failure = URLError(.cancelled)
        do {
            _ = try await stub.client().run("{ viewer { id } }")
            XCTFail("erwartet: Abbruch")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testRejectedKeyDropsTheCachedOne() async {
        let stub = Stub()
        stub.replies = [("viewer", 401, #"{"errors":[{"message":"x","extensions":{"code":"AUTHENTICATION_ERROR"}}]}"#)]
        var client = stub.client()
        var dropped = 0
        client.keyRejected = { dropped += 1 }
        _ = try? await client.run("{ viewer { id } }")
        XCTAssertEqual(dropped, 1)
    }

    func testCredentialCacheReadsOnceAndForgetsOnInvalidate() {
        let cache = TicketCredentialCache()
        var reads = 0
        var stored: String? = nil
        let read: () -> String? = { reads += 1; return stored }
        XCTAssertNil(cache.value(for: "whisperm8", read))
        XCTAssertNil(cache.value(for: "whisperm8", read))
        XCTAssertEqual(reads, 2, "ein fehlender Key wird nicht gemerkt")
        stored = "lin_api_a"
        XCTAssertEqual(cache.value(for: "whisperm8", read), "lin_api_a")
        XCTAssertEqual(cache.value(for: "whisperm8", read), "lin_api_a")
        XCTAssertEqual(reads, 3, "einmal gelesen, dann gemerkt")
        stored = "lin_api_b"
        cache.invalidate("whisperm8")
        XCTAssertEqual(cache.value(for: "whisperm8", read), "lin_api_b")
    }

    func testTestInstanceHasItsOwnKeychainService() {
        XCTAssertEqual(TicketCredentialStore.service(isTestInstance: false), "whisperm8-linear-api-key")
        XCTAssertNotEqual(TicketCredentialStore.service(isTestInstance: true), TicketCredentialStore.service(isTestInstance: false),
                          "die Test-Instanz darf den echten Key weder lesen noch überschreiben")
    }

    func testCredentialCacheKeepsWorkspacesApart() {
        let cache = TicketCredentialCache()
        XCTAssertEqual(cache.value(for: "whisperm8") { "lin_api_a" }, "lin_api_a")
        XCTAssertEqual(cache.value(for: "dealsupply") { "lin_api_b" }, "lin_api_b", "der Key des einen gilt nie für den anderen")
        cache.invalidate("dealsupply")
        XCTAssertEqual(cache.value(for: "whisperm8") { "falsch" }, "lin_api_a", "nur der abgelehnte Key wird verworfen")
        XCTAssertEqual(cache.value(for: "dealsupply") { "lin_api_c" }, "lin_api_c")
    }

    func testAccountNamesTheWorkspaceAndTeamsAreListed() async throws {
        let stub = Stub()
        stub.replies = [
            ("organization", 200, #"{"data":{"viewer":{"name":"Giuliano Costa","admin":true},"organization":{"name":"DealSupply","urlKey":"dealsupply"}}}"#),
            ("teams(first: 100)", 200, #"{"data":{"teams":{"nodes":[{"key":"PRB"},{"key":"DS"},{"key":"dea"}]}}}"#),
        ]
        let source = LinearTicketSource(client: stub.client())
        let account = try await source.account()
        XCTAssertEqual(account.workspaceKey, "dealsupply")
        XCTAssertEqual(account.workspace, "DealSupply (linear.app/dealsupply)")
        let teams = try await source.teams()
        XCTAssertEqual(teams, ["DEA", "DS", "PRB"])
    }

    func testErrorMessagesNeverContainTheKey() {
        let all: [TicketSourceError] = [.notConfigured, .unauthorized, .rateLimited, .network("x"), .notFound("WM8-1"),
                                        .rejected("y"), .invalidResponse("z"), .ambiguous("a")]
        for error in all {
            XCTAssertFalse(error.message.contains("lin_api"), "\(error)")
            XCTAssertFalse(error.message.isEmpty)
        }
    }

    // MARK: Stand-Zeile und Schlüssel

    func testStandLineReplacesOrPrepends() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 9))!
        let old = "**Stand 14.11.2026:** offen.\n\n## Ziel\nText"
        XCTAssertEqual(TicketStandLine.apply("Branch steht, wartet auf Merge. ", to: old, on: date, calendar: calendar),
                       "**Stand 15.11.2026:** Branch steht, wartet auf Merge.\n\n## Ziel\nText")
        XCTAssertEqual(TicketStandLine.apply("neu", to: "## Ziel\nText", on: date, calendar: calendar),
                       "**Stand 15.11.2026:** neu\n\n## Ziel\nText")
        XCTAssertEqual(TicketStandLine.apply("neu", to: "", on: date, calendar: calendar), "**Stand 15.11.2026:** neu")
        XCTAssertEqual(TicketStandLine.apply("neu", to: "*Stand 13.11.2026: alt.*\nRest", on: date, calendar: calendar),
                       "**Stand 15.11.2026:** neu\nRest", "auch die Jira-Schreibweise wird ersetzt")
        let twice = TicketStandLine.apply("zweiter Stand", to: TicketStandLine.apply("A\n B \n", to: old, on: date, calendar: calendar),
                                          on: date, calendar: calendar)
        XCTAssertEqual(twice, "**Stand 15.11.2026:** zweiter Stand\n\n## Ziel\nText", "mehrzeiliger Text hinterlässt keinen Rest")
    }

    func testCredentialMustFitTheCommandLine() {
        XCTAssertTrue(TicketCredentialStore.isStorable("lin_api_6jJhRlt4WFrMZxzLjr9q"))
        XCTAssertFalse(TicketCredentialStore.isStorable(""))
        XCTAssertFalse(TicketCredentialStore.isStorable("lin_api \" -w x"))
        XCTAssertFalse(TicketCredentialStore.isStorable("zeile\numbruch"))
        XCTAssertFalse(TicketCredentialStore.isStorable(String(repeating: "a", count: 513)))
    }

    private func assertThrows(_ expected: TicketSourceError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("erwartet: \(expected)", file: file, line: line)
        } catch let error as TicketSourceError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("anderer Fehler: \(error)", file: file, line: line)
        }
    }
}
