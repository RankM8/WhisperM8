import XCTest
@testable import WhisperM8

/// Gespeicherte Ansichten aus Linear als Reiter (WM8-125): Abruf, Standard und
/// Übersetzung der Einstellungen.
final class TicketViewTests: XCTestCase {
    private final class Stub: @unchecked Sendable {
        var queries: [(query: String, variables: [String: Any])] = []
        var replies: [(needle: String, body: String)] = []

        func client() -> LinearGraphQLClient {
            LinearGraphQLClient(apiKey: { "lin_api_test" }, transport: { [self] request in
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
                let query = body["query"] as? String ?? ""
                queries.append((query, body["variables"] as? [String: Any] ?? [:]))
                let reply = replies.first { query.contains($0.needle) }?.body ?? #"{"data":{}}"#
                return (Data(reply.utf8), 200)
            })
        }
    }

    private func viewJSON(_ id: String, _ name: String, team: String? = "WM8", grouping: String = "workflowState",
                          model: String = "Issue") -> String {
        let teamJSON = team.map { #"{"key":"\#($0)"}"# } ?? "null"
        return """
        {"id":"\(id)","name":"\(name)","slugId":"slug-\(id)","modelName":"\(model)","team":\(teamJSON),
         "viewPreferencesValues":{"issueGrouping":"\(grouping)","viewOrdering":"priority","showSubIssues":true}}
        """
    }

    private func view(_ id: String, _ name: String) -> TicketView {
        TicketView(id: id, name: name, teamKey: "WM8", grouping: .status, ordering: .priority, showsSubIssues: true, url: nil)
    }

    // MARK: Standard und Reihenfolge

    func testFavoritesKeepTheirOrderAndPersonalNextIsDefault() {
        let catalog = TicketViewCatalog.make(
            favorites: [view("a", "All issues"), view("n", "Als Nächstes: Giuliano"), view("w", "Wartet auf mich")],
            candidates: [], viewerName: "Giuliano Costa")
        XCTAssertEqual(catalog.views.map(\.id), ["a", "n", "w"])
        XCTAssertEqual(catalog.defaultID, "n")
    }

    func testPersonalNextOutsideFavoritesGoesFirst() {
        let catalog = TicketViewCatalog.make(
            favorites: [view("a", "All issues"), view("w", "Wartet auf mich")],
            candidates: [view("x", "Als Nächstes: Erika"), view("t", "Als Nächstes"), view("n", "Als Nächstes: Giuliano")],
            viewerName: "Giuliano Costa")
        XCTAssertEqual(catalog.views.map(\.id), ["n", "a", "w"])
        XCTAssertEqual(catalog.defaultID, "n")
    }

    func testWithoutPersonalNextTheFirstFavoriteIsDefault() {
        let catalog = TicketViewCatalog.make(favorites: [view("a", "All issues"), view("t", "Als Nächstes")],
                                             candidates: [view("t", "Als Nächstes")], viewerName: "Giuliano Costa")
        XCTAssertEqual(catalog.views.map(\.id), ["a", "t"])
        XCTAssertEqual(catalog.defaultID, "a")
        XCTAssertEqual(TicketViewCatalog.make(favorites: [], candidates: [], viewerName: "").defaultID, nil)
    }

    func testGroupingAndOrderingFromLinear() {
        XCTAssertEqual(TicketViewGrouping(linear: "workflowState"), .status)
        XCTAssertEqual(TicketViewGrouping(linear: nil), .status)
        XCTAssertEqual(TicketViewGrouping(linear: "project"), .project)
        XCTAssertEqual(TicketViewGrouping(linear: "priority"), .priority)
        XCTAssertEqual(TicketViewGrouping(linear: "assignee"), .assignee)
        XCTAssertEqual(TicketViewGrouping(linear: "noGrouping"), .none)
        XCTAssertEqual(TicketViewGrouping(linear: "cycle"), .unsupported("cycle"))
        XCTAssertEqual(TicketViewOrdering(linear: "updatedAt"), .updated)
        XCTAssertEqual(TicketViewOrdering(linear: "manual"), .priority)
    }

    // MARK: Abruf

    func testViewsAreReadInOneRequestWithoutProjectViews() async throws {
        let stub = Stub()
        stub.replies = [("favorites", """
        {"data":{"viewer":{"name":"Giuliano Costa"},"organization":{"urlKey":"whisperm8"},
         "favorites":{"nodes":[
           {"sortOrder":3,"parent":null,"customView":\(viewJSON("w", "Wartet auf mich", grouping: "project"))},
           {"sortOrder":1,"parent":null,"customView":\(viewJSON("a", "All issues", team: nil))},
           {"sortOrder":2,"parent":null,"customView":\(viewJSON("p", "Laufende Vorhaben", model: "Project"))},
           {"sortOrder":0,"parent":null,"customView":null},
           {"sortOrder":-5,"parent":{"sortOrder":5},"customView":\(viewJSON("f", "Im Ordner"))}
         ]},
         "customViews":{"nodes":[\(viewJSON("n", "Als Nächstes: Giuliano"))]}}}
        """)]
        let catalog = try await LinearTicketSource(client: stub.client()).views()
        XCTAssertEqual(stub.queries.count, 1)
        XCTAssertEqual(catalog.views.map(\.id), ["n", "a", "w", "f"])
        XCTAssertEqual(catalog.defaultID, "n")
        let waiting = catalog.views.first { $0.id == "w" }
        XCTAssertEqual(waiting?.grouping, .project)
        XCTAssertEqual(waiting?.url, "https://linear.app/whisperm8/view/slug-w")
        XCTAssertNil(catalog.views.first { $0.id == "a" }?.teamKey)
    }

    func testTicketsOfAViewCarryTheirParent() async throws {
        let stub = Stub()
        stub.replies = [("customView(id:", """
        {"data":{"customView":{"issues":{"nodes":[
          {"id":"i1","identifier":"WM8-15","title":"Handtests","description":"","priority":3,"url":"u",
           "state":{"id":"s1","name":"Todo","type":"unstarted","position":1},"labels":{"nodes":[]},
           "attachments":{"nodes":[]},"inverseRelations":{"nodes":[]},"parent":{"identifier":"WM8-91"}},
          {"id":"i2","identifier":"ABC-3","title":"Erfundenes anderes Team","description":"","priority":0,"url":"u",
           "state":{"id":"s2","name":"Backlog","type":"backlog","position":0},"labels":{"nodes":[]},
           "attachments":{"nodes":[]},"inverseRelations":{"nodes":[]},"parent":null}
        ],"pageInfo":{"hasNextPage":false}}}}}
        """)]
        let tickets = try await LinearTicketSource(client: stub.client()).tickets(inView: "view-1")
        XCTAssertEqual(tickets.map(\.key), ["WM8-15", "ABC-3"])
        XCTAssertEqual(tickets.first?.parentKey, "WM8-91")
        XCTAssertNil(tickets.last?.parentKey)
        XCTAssertEqual(stub.queries.first?.variables["id"] as? String, "view-1")
    }

    func testUnknownViewIsNotFound() async {
        let stub = Stub()
        stub.replies = [("customView(id:", #"{"data":{"customView":null}}"#)]
        do {
            _ = try await LinearTicketSource(client: stub.client()).tickets(inView: "weg")
            XCTFail("erwartet: nicht gefunden")
        } catch {
            XCTAssertEqual(error as? TicketSourceError, .notFound("Ansicht"))
        }
    }
}
