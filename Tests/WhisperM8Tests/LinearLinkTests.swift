import XCTest
@testable import WhisperM8

/// Linear-Links (WM8-132): Adresse zerlegen, `linear://` bauen, entscheiden,
/// ob Board, Linear-App oder Browser, und der Rückfall, wenn das Board nicht
/// geht. Kein AppKit, kein Linear, keine echten Klicks.
@MainActor
final class LinearLinkTests: XCTestCase {
    private func link(_ string: String) -> LinearLink? { LinearLink(string: string) }

    // MARK: Zerlegen

    func testTicketAddressGivesWorkspaceKeyAndDesktopAddress() throws {
        let parsed = try XCTUnwrap(link("https://linear.app/WhisperM8/issue/wm8-131/ticket-von-aussen-im-board"))
        XCTAssertEqual(parsed.workspace, "whisperm8")
        XCTAssertEqual(parsed.issueKey, "WM8-131")
        XCTAssertEqual(parsed.desktopURL.absoluteString, "linear://WhisperM8/issue/wm8-131/ticket-von-aussen-im-board")
        XCTAssertEqual(parsed.webURL.absoluteString, "https://linear.app/WhisperM8/issue/wm8-131/ticket-von-aussen-im-board")
    }

    func testTicketWithoutSlugAndWithQueryAndFragment() throws {
        let bare = try XCTUnwrap(link("https://linear.app/whisperm8/issue/WM8-12"))
        XCTAssertEqual(bare.issueKey, "WM8-12")
        XCTAssertEqual(bare.desktopURL.absoluteString, "linear://whisperm8/issue/WM8-12")

        let anchored = try XCTUnwrap(link("https://linear.app/whisperm8/issue/WM8-12/titel?noRedirect=1#comment-ab12"))
        XCTAssertEqual(anchored.issueKey, "WM8-12")
        XCTAssertEqual(anchored.desktopURL.absoluteString, "linear://whisperm8/issue/WM8-12/titel?noRedirect=1#comment-ab12")
    }

    func testPercentEncodedSlugStaysAsItCame() throws {
        let parsed = try XCTUnwrap(link("https://linear.app/whisperm8/issue/WM8-7/%C3%B6ffnen"))
        XCTAssertEqual(parsed.desktopURL.absoluteString, "linear://whisperm8/issue/WM8-7/%C3%B6ffnen")
    }

    func testProjectsViewsAndDocumentsAreLinearPagesWithoutKey() throws {
        for address in [
            "https://linear.app/whisperm8/project/tickets-4f2a/overview",
            "https://linear.app/whisperm8/view/offen-1a2b",
            "https://linear.app/whisperm8/document/plan-9c8d",
            "https://linear.app/whisperm8/team/WM8/active",
        ] {
            let parsed = try XCTUnwrap(link(address), address)
            XCTAssertNil(parsed.issueKey, address)
            XCTAssertEqual(parsed.desktopURL.absoluteString, "linear://" + address.dropFirst("https://linear.app/".count))
        }
        // „issue“ ohne gültige Nummer ist keine Ticket-Adresse, bleibt aber Linear.
        XCTAssertNil(try XCTUnwrap(link("https://linear.app/whisperm8/issue/kein-ticket")).issueKey)
    }

    func testForeignHostsWebsiteAndBareWorkspaceAreNoLinearPages() {
        XCTAssertNil(link("https://example.com/whisperm8/issue/WM8-1"))
        XCTAssertNil(link("https://linear.app.example.com/whisperm8/issue/WM8-1"))
        XCTAssertNil(link("https://uploads.linear.app/abc/def"))
        XCTAssertNil(link("https://linear.app/docs/get-the-app"))
        XCTAssertNil(link("https://linear.app/changelog/2026-11-01"))
        XCTAssertNil(link("https://linear.app/whisperm8"))
        XCTAssertNil(link("https://linear.app/"))
        XCTAssertNil(link("linear://whisperm8/issue/WM8-1"))
        XCTAssertNil(link("ftp://linear.app/whisperm8/issue/WM8-1"))
        XCTAssertNotNil(link("https://www.linear.app/whisperm8/issue/WM8-1"))
        XCTAssertNotNil(link("http://linear.app/whisperm8/issue/WM8-1"))
    }

    // MARK: Entscheiden

    private let ticket = LinearLink(string: "https://linear.app/whisperm8/issue/WM8-5/titel")!
    private let project = LinearLink(string: "https://linear.app/whisperm8/project/tickets-4f2a")!

    private func decide(_ link: LinearLink, _ gesture: LinearLinkRoute.Gesture, _ target: LinearLinkTarget,
                        app: Bool = true) -> LinearLinkRoute.Action {
        LinearLinkRoute.decide(link, gesture: gesture, target: target, appInstalled: app)
    }

    func testClickInChatFollowsTheSetting() {
        XCTAssertEqual(decide(ticket, .chatClick, .board),
                       .board(key: "WM8-5", workspace: "whisperm8", fallback: ticket.desktopURL))
        XCTAssertEqual(decide(ticket, .chatClick, .app), .open(ticket.desktopURL))
        XCTAssertEqual(decide(ticket, .chatClick, .browser), .open(ticket.webURL))
    }

    func testOtherLinearPagesNeverGoToTheBoard() {
        XCTAssertEqual(decide(project, .chatClick, .board), .open(project.desktopURL))
        XCTAssertEqual(decide(project, .chatClick, .board, app: false), .open(project.webURL))
    }

    func testAlternateClickAlwaysOpensTheApp() {
        for target in LinearLinkTarget.allCases {
            XCTAssertEqual(decide(ticket, .chatAlternateClick, target), .open(ticket.desktopURL), "\(target)")
        }
    }

    func testOpenInLinearUsesTheAppUnlessBrowserIsChosen() {
        XCTAssertEqual(decide(ticket, .openInLinear, .board), .open(ticket.desktopURL))
        XCTAssertEqual(decide(ticket, .openInLinear, .app), .open(ticket.desktopURL))
        XCTAssertEqual(decide(ticket, .openInLinear, .browser), .open(ticket.webURL))
    }

    func testWithoutTheAppEverythingGoesToTheBrowserAsBefore() {
        XCTAssertEqual(decide(ticket, .chatClick, .board, app: false),
                       .board(key: "WM8-5", workspace: "whisperm8", fallback: ticket.webURL))
        XCTAssertEqual(decide(ticket, .chatClick, .app, app: false), .open(ticket.webURL))
        XCTAssertEqual(decide(ticket, .chatAlternateClick, .board, app: false), .open(ticket.webURL))
        XCTAssertEqual(decide(ticket, .openInLinear, .board, app: false), .open(ticket.webURL))
    }

    func testStoredSettingFallsBackToTheBoard() {
        XCTAssertEqual(LinearLinkTarget(stored: nil), .board)
        XCTAssertEqual(LinearLinkTarget(stored: "unbekannt"), .board)
        XCTAssertEqual(LinearLinkTarget(stored: "browser"), .browser)

        let defaults = UserDefaults(suiteName: "LinearLinkTests-\(UUID().uuidString)")!
        let prefs = AppPreferences(defaults: defaults)
        XCTAssertEqual(prefs.linearLinkTarget, .board)
        prefs.linearLinkTarget = .app
        XCTAssertEqual(defaults.string(forKey: PreferenceKeys.linearLinkTarget), "app")
        XCTAssertEqual(prefs.linearLinkTarget, .app)
    }

    // MARK: Ausführen

    private final class Opened {
        var urls: [URL] = []
        var boards: [String] = []
    }

    private func opener(_ opened: Opened, target: LinearLinkTarget = .board, boardWorks: Bool) -> LinearLinkOpener {
        LinearLinkOpener(
            target: { target },
            appInstalled: { true },
            openURL: { opened.urls.append($0) },
            openBoard: { key, workspace in
                opened.boards.append("\(workspace)/\(key)")
                return boardWorks
            })
    }

    func testBoardShowsTheTicketAndOpensNothingElse() async {
        let opened = Opened()
        await opener(opened, boardWorks: true).open(ticket, gesture: .chatClick)?.value
        XCTAssertEqual(opened.boards, ["whisperm8/WM8-5"])
        XCTAssertEqual(opened.urls, [])
    }

    func testWithoutBoardTheClickGoesToTheApp() async {
        let opened = Opened()
        await opener(opened, boardWorks: false).open(ticket, gesture: .chatClick)?.value
        XCTAssertEqual(opened.boards, ["whisperm8/WM8-5"])
        XCTAssertEqual(opened.urls, [ticket.desktopURL])
    }

    func testOpenInLinearButtonAndForeignAddresses() {
        let opened = Opened()
        let button = opener(opened, boardWorks: true)
        button.openInLinear(ticket.webURL)
        let foreign = URL(string: "https://example.com/x")!
        button.openInLinear(foreign)
        XCTAssertEqual(opened.urls, [ticket.desktopURL, foreign])
        XCTAssertEqual(opened.boards, [], "der Knopf geht nie ins Board")
    }

    // MARK: Klick im Terminal

    private func resolve(_ link: String, alternate: Bool = false) -> TerminalLinkResolver.Action {
        TerminalLinkResolver.resolve(link: link, workingDirectory: "/work", revealInFinder: alternate,
                                     fileStatus: { _ in .missing })
    }

    func testTerminalRoutesLinearPagesAndLeavesTheRestAlone() {
        XCTAssertEqual(resolve("https://linear.app/whisperm8/issue/WM8-5/titel"), .openLinear(ticket, alternate: false))
        XCTAssertEqual(resolve("https://linear.app/whisperm8/issue/WM8-5/titel", alternate: true),
                       .openLinear(ticket, alternate: true))
        XCTAssertEqual(resolve("https://linear.app/docs/get-the-app"),
                       .openWeb(URL(string: "https://linear.app/docs/get-the-app")!))
        XCTAssertEqual(resolve("https://example.com/issue/WM8-5"), .openWeb(URL(string: "https://example.com/issue/WM8-5")!))
    }
}
