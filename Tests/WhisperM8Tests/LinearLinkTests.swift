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
        // K2: Freigabeliste für den zweiten Teil; Unbekanntes bleibt im Browser.
        XCTAssertNil(link("https://linear.app/whisperm8/irgendwas/neu"))
        XCTAssertNil(link("https://linear.app/customers/acme"))
        XCTAssertNil(link("https://linear.app/blog/how-we-build"))
        XCTAssertNotNil(link("https://linear.app/whisperm8/inbox"))
        XCTAssertNotNil(link("https://linear.app/whisperm8/settings/api"))
        XCTAssertNotNil(link("https://linear.app/whisperm8/initiative/plan-1a2b"))
        XCTAssertNotNil(link("https://linear.app/whisperm8/Issue/WM8-1"))
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
        var presented = 0
    }

    /// `board`: Antwort von Linear (nach `linearAnswers`); `true` heißt
    /// „ladbar“, gezeigt wird nur, wenn `shouldPresent` ja sagt.
    private func opener(_ opened: Opened, target: LinearLinkTarget = .board, boardWorks: Bool,
                        appActive: @escaping () -> Bool = { true },
                        linearAnswers: @escaping () async -> Void = {},
                        deadline: @escaping () async -> Void = { try? await Task.sleep(for: .seconds(3600)) },
                        attempts: LinearLinkAttempts? = nil) -> LinearLinkOpener {
        LinearLinkOpener(
            target: { target },
            appInstalled: { true },
            openURL: { opened.urls.append($0) },
            openBoard: { key, workspace, shouldPresent in
                opened.boards.append("\(workspace)/\(key)")
                await linearAnswers()
                guard boardWorks, shouldPresent() else { return false }
                opened.presented += 1
                return true
            },
            isAppActive: appActive,
            waitForDeadline: deadline,
            attempts: attempts ?? LinearLinkAttempts())
    }

    func testBoardShowsTheTicketAndOpensNothingElse() async {
        let opened = Opened()
        await opener(opened, boardWorks: true).open(ticket, gesture: .chatClick)?.value
        XCTAssertEqual(opened.boards, ["whisperm8/WM8-5"])
        XCTAssertEqual(opened.presented, 1)
        XCTAssertEqual(opened.urls, [])
    }

    func testWithoutBoardTheClickGoesToTheApp() async {
        let opened = Opened()
        await opener(opened, boardWorks: false).open(ticket, gesture: .chatClick)?.value
        XCTAssertEqual(opened.boards, ["whisperm8/WM8-5"])
        XCTAssertEqual(opened.urls, [ticket.desktopURL])
    }

    /// K1: Linear antwortet erst nach der Frist. Der Klick geht dann in die
    /// Linear-App, und die späte Antwort holt kein Board mehr nach vorn.
    func testSlowLinearFallsBackOnceAndTheLateAnswerShowsNothing() async {
        let opened = Opened()
        let (answer, release) = AsyncStream<Void>.makeStream()
        let (deadlinePassed, passDeadline) = AsyncStream<Void>.makeStream()
        let work = opener(opened, boardWorks: true,
                          linearAnswers: { for await _ in answer { return } },
                          deadline: { for await _ in deadlinePassed { return } })
            .open(ticket, gesture: .chatClick)
        passDeadline.yield()
        await settle { opened.urls.count == 1 }
        XCTAssertEqual(opened.urls, [ticket.desktopURL])
        release.yield()
        await work?.value
        XCTAssertEqual(opened.presented, 0, "zu spät: kein Board")
        XCTAssertEqual(opened.urls, [ticket.desktopURL], "kein zweiter Rückfall")
    }

    /// K1: Der Nutzer ist inzwischen in einer anderen App: weder Board noch
    /// Linear-App kommen nach vorn.
    func testNothingComesToFrontWhenTheAppIsNoLongerActive() async {
        let opened = Opened()
        await opener(opened, boardWorks: true, appActive: { false }).open(ticket, gesture: .chatClick)?.value
        XCTAssertEqual(opened.presented, 0)
        XCTAssertEqual(opened.urls, [])

        let failing = Opened()
        await opener(failing, boardWorks: false, appActive: { false }).open(ticket, gesture: .chatClick)?.value
        XCTAssertEqual(failing.urls, [], "auch der Rückfall nicht")
    }

    /// K1: Die Frist läuft ab, während das Board schon gezeigt wird: kein
    /// zusätzlicher Rückfall in die Linear-App.
    func testDeadlineDuringPresentingKeepsTheBoard() {
        let attempt = LinearLinkAttempts().begin()!
        XCTAssertTrue(attempt.startPresenting(appActive: true))
        XCTAssertFalse(attempt.expire())
        XCTAssertTrue(attempt.finish())
    }

    /// K1: Ein zweiter Klick, während das erste Öffnen läuft, wird verworfen;
    /// danach geht es wieder.
    func testSecondClickWhileOpeningIsDropped() async {
        let opened = Opened()
        let attempts = LinearLinkAttempts()
        let (answer, release) = AsyncStream<Void>.makeStream()
        let first = opener(opened, boardWorks: true, linearAnswers: { for await _ in answer { return } },
                           attempts: attempts).open(ticket, gesture: .chatClick)
        XCTAssertTrue(attempts.isBusy)
        let second = opener(opened, boardWorks: true, attempts: attempts).open(ticket, gesture: .chatClick)
        XCTAssertNil(second)
        release.yield()
        await first?.value
        XCTAssertEqual(opened.boards, ["whisperm8/WM8-5"])
        XCTAssertFalse(attempts.isBusy)
        await opener(opened, boardWorks: true, attempts: attempts).open(ticket, gesture: .chatClick)?.value
        XCTAssertEqual(opened.presented, 2)
    }

    private func settle(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), file: file, line: line)
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
