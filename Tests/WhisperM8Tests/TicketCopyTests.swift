import XCTest
@testable import WhisperM8

/// Link und Liste kopieren: Text, Taste ⌘C, was das ViewModel kopiert, und
/// die Prüfung der Regel in `tickets doctor`.
@MainActor
final class TicketCopyTests: XCTestCase {
    func testLinkIsKeyTitleAndAddressOnTwoLines() {
        var ticket = TicketFixtures.ticket(104, title: "Insel per Tastatur\nbauen")
        ticket.url = "https://linear.app/whisperm8/issue/WM8-104"
        XCTAssertEqual(TicketCopyText.link(ticket), "WM8-104 Insel per Tastatur bauen\nhttps://linear.app/whisperm8/issue/WM8-104")
        ticket.url = "file:///etc/passwd"
        XCTAssertEqual(TicketCopyText.link(ticket), "WM8-104 Insel per Tastatur bauen", "nur https-Adressen")
    }

    func testControlAndFormatCharactersNeverReachTheClipboard() {
        var ticket = TicketFixtures.ticket(7, title: "Vorher\u{1B}[201~danach")
        ticket.url = "https://linear.app/whisperm8/issue/WM8-7"
        let link = TicketCopyText.link(ticket)
        XCTAssertFalse(link.unicodeScalars.contains("\u{1B}"), "ESC beendete sonst ein Bracketed Paste im Terminal")
        XCTAssertEqual(link.components(separatedBy: "\n").first, "WM8-7 Vorher [201~danach")
        ticket.title = "Rechnung \u{202E}fdp.exe"
        XCTAssertEqual(TicketCopyText.link(ticket).components(separatedBy: "\n").first, "WM8-7 Rechnung fdp.exe", "Bidi-Umkehr fällt weg")
        ticket.title = "Zwei\nZeilen\r\nund\u{2028}mehr"
        XCTAssertEqual(TicketCopyText.link(ticket).components(separatedBy: "\n").count, 2, "Titel bleibt eine Zeile")
        XCTAssertEqual(TicketCopyText.link(ticket).components(separatedBy: "\n").first, "WM8-7 Zwei Zeilen und mehr")
        let list = TicketCopyText.list(title: "Liste\u{1B}", sections: [.init(title: "To\u{202E}do", tickets: [ticket])])
        XCTAssertFalse(list.unicodeScalars.contains { $0.properties.generalCategory == .control && $0 != "\n" })
        XCTAssertFalse(list.unicodeScalars.contains { $0.properties.generalCategory == .format })
        XCTAssertEqual(TicketCopyText.flat("Ü-Umlaut und Emoji 🎫 bleiben"), "Ü-Umlaut und Emoji 🎫 bleiben")
    }

    func testListKeepsOrderAndDropsEmptySections() {
        let one = TicketFixtures.ticket(1, title: "Eins"), two = TicketFixtures.ticket(2, title: "Zwei")
        let text = TicketCopyText.list(title: "Tickets · whisperm8", sections: [
            .init(title: "Merge-bereit", tickets: [two]), .init(title: "Leer", tickets: []), .init(title: "Todo", tickets: [one]),
        ])
        XCTAssertEqual(text, """
        Tickets · whisperm8

        Merge-bereit
        - WM8-2 Zwei https://linear.app/x/issue/WM8-2

        Todo
        - WM8-1 Eins https://linear.app/x/issue/WM8-1
        """)
    }

    func testCommandCIsCopyLink() {
        XCTAssertEqual(TicketBoardKey.resolve(keyCode: 8, characters: "c", modifiers: .command), .copyLink)
        XCTAssertNil(TicketBoardKey.resolve(keyCode: 8, characters: "c", modifiers: [.command, .shift]),
                     "⌘⇧C bleibt der Zwischenablage-Verlauf")
        XCTAssertNil(TicketBoardKey.resolve(keyCode: 8, characters: "c", modifiers: []))
    }

    private func viewModel() -> (TicketBoardViewModel, () -> [String]) {
        let model = TicketBoardBuilder.build(snapshot: TicketFixtures.snapshot([
            TicketFixtures.ticket(1, status: "Todo", priority: 1, project: "B"),
            TicketFixtures.ticket(2, status: "Todo", priority: 2, project: "A"),
            TicketFixtures.ticket(4, status: "In Progress", project: "A"),
        ]), chats: [], projectPath: nil)
        let viewModel = TicketBoardViewModel(model: model, documents: .immediate)
        var copied: [String] = []
        viewModel.copyToClipboard = { copied.append($0) }
        return (viewModel, { copied })
    }

    func testCopyLinkNeedsAChosenTicketAndCopyListFollowsTheView() {
        let (viewModel, copied) = viewModel()
        XCTAssertFalse(viewModel.handle(.copyLink), "ohne gewähltes Ticket gehört ⌘C dem Fenster")
        viewModel.selectedKey = "WM8-4"
        XCTAssertTrue(viewModel.handle(.copyLink))
        XCTAssertEqual(copied().last, "WM8-4 Ticket 4\nhttps://linear.app/x/issue/WM8-4")
        XCTAssertEqual(viewModel.copied, .link)

        viewModel.copyList(title: "Board")
        XCTAssertEqual(copied().last?.components(separatedBy: "\n").filter { $0.hasPrefix("- ") },
                       ["- WM8-4 Ticket 4 https://linear.app/x/issue/WM8-4", "- WM8-1 Ticket 1 https://linear.app/x/issue/WM8-1",
                        "- WM8-2 Ticket 2 https://linear.app/x/issue/WM8-2"], "Board: Spalte für Spalte")
        viewModel.openFromLane("WM8-2")
        XCTAssertTrue(viewModel.handle(.copyLink))
        XCTAssertTrue(copied().last?.hasPrefix("WM8-2 ") == true, "in der Triage das gezeigte Ticket")
        viewModel.copyList(title: "Triage")
        XCTAssertTrue(copied().last?.hasPrefix("Triage\n\nTodo\n- WM8-1") == true, copied().last ?? "")
    }

    func testDoctorFindsRuleStatusesTheTeamDoesNotHave() {
        let rule = TicketTeamRule(statusMeanings: ["Merge-bereit": .waitsForMe, "Merge-breit": .waitsForMe, "Done": .done])
        let problems = TicketTeamRuleChange.statusProblems(in: rule, statuses: TicketFixtures.statuses)
        XCTAssertEqual(problems.map(\.name), ["Done", "Merge-breit"], "Tippfehler und erledigte Status")
        XCTAssertEqual(problems.map(\.closed), [true, false], "geschlossen ist etwas anderes als „gibt es nicht“")
    }
}
