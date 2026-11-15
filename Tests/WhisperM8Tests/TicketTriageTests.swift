import AppKit
import SwiftUI
import XCTest
@testable import WhisperM8

/// Triage: Auswahl-Logik (pur), Tasten, Ablauf im ViewModel, Kommentare aus
/// Linear und der Text in der Mitte.
@MainActor
final class TicketTriageTests: XCTestCase {
    private func triage(_ keys: [String], at key: String) -> TicketTriage {
        TicketBoardSelection.open(key, keys: keys, source: .lane(statusID: "s1"), title: "Todo")!
    }

    // MARK: Auswahl

    func testNextPreviousStopAtTheEnds() {
        var t = triage(["A", "B", "C"], at: "B")
        XCTAssertEqual(t.index, 1)
        t = TicketBoardSelection.next(t)
        XCTAssertEqual(t.current, "C")
        XCTAssertFalse(t.hasNext)
        XCTAssertEqual(TicketBoardSelection.next(t).current, "C", "kein Sprung an den Anfang")
        t = TicketBoardSelection.previous(TicketBoardSelection.previous(t))
        XCTAssertEqual(t.current, "A")
        XCTAssertEqual(TicketBoardSelection.previous(t).current, "A")
        XCTAssertEqual(TicketBoardSelection.select("C", in: t).current, "C")
        XCTAssertEqual(TicketBoardSelection.select("X", in: t).current, "A", "unbekannt: bleibt")
        XCTAssertEqual(TicketBoardSelection.close(t), "A")
        XCTAssertNil(TicketBoardSelection.open("X", keys: ["A"], source: .list, title: "List"))
    }

    func testReconcileKeepsTicketOrTakesTheNeighbour() {
        let t = triage(["A", "B", "C", "D"], at: "B")
        XCTAssertEqual(TicketBoardSelection.reconcile(t, fresh: ["C", "B"])?.current, "B", "bleibt, wo es steht")
        XCTAssertEqual(TicketBoardSelection.reconcile(t, fresh: ["A", "C", "D"])?.current, "C", "Nachfolger rückt nach")
        XCTAssertEqual(TicketBoardSelection.reconcile(t, fresh: ["A", "D"])?.current, "D")
        XCTAssertEqual(TicketBoardSelection.reconcile(triage(["A", "B"], at: "B"), fresh: ["A"])?.current, "A", "am Ende der Vorgänger")
        XCTAssertEqual(TicketBoardSelection.reconcile(t, fresh: ["X", "Y"])?.current, "Y", "nichts Bekanntes: dieselbe Stelle")
        XCTAssertNil(TicketBoardSelection.reconcile(t, fresh: []), "leere Liste schließt die Triage")
    }

    // MARK: Board

    private func columns() -> [TicketBoardColumnKeys] {
        [
            TicketBoardColumnKeys(id: "a", keys: ["A1", "A2", "A3"], hidden: 0, isFolded: false),
            TicketBoardColumnKeys(id: "b", keys: [], hidden: 0, isFolded: true),
            TicketBoardColumnKeys(id: "c", keys: ["C1"], hidden: 4, isFolded: false),
            TicketBoardColumnKeys(id: "d", keys: [], hidden: 0, isFolded: false),
        ]
    }

    func testBoardMovesSkipFoldedAndEmptyColumns() {
        let cols = columns()
        XCTAssertEqual(TicketBoardSelection.start(preferred: nil, in: cols), "A1")
        XCTAssertEqual(TicketBoardSelection.start(preferred: "C1", in: cols), "C1")
        XCTAssertEqual(TicketBoardSelection.start(preferred: "weg", in: cols), "A1")
        XCTAssertEqual(TicketBoardSelection.move("A1", .down, in: cols), "A2")
        XCTAssertEqual(TicketBoardSelection.move("A3", .down, in: cols), "A3", "am Rand stehen bleiben")
        XCTAssertEqual(TicketBoardSelection.move("A1", .up, in: cols), "A1")
        XCTAssertEqual(TicketBoardSelection.move("A3", .right, in: cols), "C1", "eingeklappte Spalte übersprungen, Zeile so nah wie möglich")
        XCTAssertEqual(TicketBoardSelection.move("C1", .right, in: cols), "C1", "rechts nur noch eine leere Spalte")
        XCTAssertEqual(TicketBoardSelection.move("C1", .left, in: cols), "A1")
        XCTAssertEqual(TicketBoardSelection.move(nil, .right, in: cols), "A1", "ohne Auswahl: Start")
        XCTAssertNil(TicketBoardSelection.move(nil, .down, in: [cols[1], cols[3]]))
        XCTAssertEqual(TicketBoardSelection.position(of: "A2", in: cols)?.row, 1)
    }

    func testBoardColumnsUseTheSameCutAsTheView() {
        let entries = (1...10).map { TicketBoardEntry(ticket: TicketFixtures.ticket($0, status: "Backlog"), agents: []) }
        let lane = TicketBoardLane(status: TicketFixtures.status("Backlog"), meaning: nil, entries: entries)
        let column = TicketBoardSelection.columns([lane])[0]
        XCTAssertEqual(column.keys.count, TicketBoardLanes.cardLimit)
        XCTAssertEqual(column.hidden, 10 - TicketBoardLanes.cardLimit)
    }

    func testViewModelMovesOnBoardAndOpensSelected() {
        let viewModel = TicketBoardViewModel(model: model(), documents: .immediate)
        viewModel.moveOnBoard(.down)
        XCTAssertEqual(viewModel.selectedKey, "WM8-4", "Start: oberste Karte der ersten Spalte (In Progress)")
        viewModel.moveOnBoard(.right)
        XCTAssertEqual(viewModel.selectedKey, "WM8-1")
        viewModel.openSelected()
        XCTAssertEqual(viewModel.triage?.current, "WM8-1")
        viewModel.moveOnBoard(.down)
        XCTAssertEqual(viewModel.selectedKey, "WM8-1", "in der Triage bewegt das Board nichts")
    }

    // MARK: Tasten

    func testKeys() {
        XCTAssertEqual(TicketBoardKey.resolve(keyCode: 38, characters: "j", modifiers: []), .next)
        XCTAssertEqual(TicketBoardKey.resolve(keyCode: 40, characters: "k", modifiers: []), .previous)
        XCTAssertEqual(TicketBoardKey.resolve(keyCode: 125, characters: nil, modifiers: []), .next)
        XCTAssertEqual(TicketBoardKey.resolve(keyCode: 126, characters: nil, modifiers: []), .previous)
        XCTAssertEqual(TicketBoardKey.resolve(keyCode: 53, characters: "\u{1b}", modifiers: []), .close)
        XCTAssertNil(TicketBoardKey.resolve(keyCode: 38, characters: "j", modifiers: .command), "⌘J gehört später dem Board-Chat")
        XCTAssertNil(TicketBoardKey.resolve(keyCode: 38, characters: "J", modifiers: .shift))
        XCTAssertNil(TicketBoardKey.resolve(keyCode: 0, characters: "a", modifiers: []))
    }

    // MARK: Ablauf im ViewModel

    private func model() -> TicketBoardModel {
        TicketBoardBuilder.build(snapshot: TicketFixtures.snapshot([
            TicketFixtures.ticket(1, status: "Todo", priority: 1, project: "B"),
            TicketFixtures.ticket(2, status: "Todo", priority: 2, project: "A"),
            TicketFixtures.ticket(3, status: "Todo", priority: 3, project: "A"),
            TicketFixtures.ticket(4, status: "In Progress", project: "A"),
        ]), chats: [], projectPath: nil)
    }

    func testOpenFromLaneAndListAndKeysOnlyActWithTriage() {
        let viewModel = TicketBoardViewModel(model: model(), documents: .immediate)
        var shown: [String?] = []
        viewModel.onShowTicket = { shown.append($0?.key) }
        XCTAssertFalse(viewModel.handle(.next), "ohne Triage geht die Taste weiter")

        viewModel.openFromLane("WM8-2")
        XCTAssertEqual(viewModel.triage?.keys, ["WM8-1", "WM8-2", "WM8-3"])
        XCTAssertEqual(viewModel.triage?.title, "Todo")
        XCTAssertEqual(viewModel.detail?.entry.ticket.key, "WM8-2")
        XCTAssertTrue(viewModel.handle(.next))
        XCTAssertEqual(viewModel.selectedKey, "WM8-3")
        XCTAssertEqual(shown, ["WM8-2", "WM8-3"])
        XCTAssertEqual(viewModel.document?.ticketKey, "WM8-3")
        XCTAssertTrue(viewModel.handle(.close))
        XCTAssertNil(viewModel.triage)
        XCTAssertEqual(shown.last, .some(nil))

        viewModel.mode = .list
        viewModel.openFromList("WM8-4")
        XCTAssertEqual(viewModel.triage?.keys, ["WM8-2", "WM8-3", "WM8-4", "WM8-1"], "Reihenfolge der Liste (nach Projekt)")
    }

    func testRefreshKeepsTriageAndLateCommentsForAnotherTicketAreIgnored() {
        let viewModel = TicketBoardViewModel(model: model(), documents: .immediate)
        viewModel.openFromLane("WM8-2")
        let one = TicketComments(items: [TicketComment(id: "c", author: "", createdAt: nil, body: "spät", isReply: false)], hasMore: false)
        viewModel.nextInTriage()
        viewModel.setComments(.loaded(one), ticketID: "id-2")
        XCTAssertEqual(viewModel.comments, .loading, "Antwort für ein Ticket, das nicht mehr gezeigt wird")

        // Neuer Abzug: WM8-3 ist erledigt, der Nachbar rückt nach.
        var entries = model().entries
        entries.removeAll { $0.ticket.key == "WM8-3" }
        viewModel.update(TicketBoardModel(entries: entries, looseChats: [], supervisors: [], statuses: TicketFixtures.statuses))
        XCTAssertEqual(viewModel.triage?.keys, ["WM8-1", "WM8-2"])
        XCTAssertEqual(viewModel.triage?.current, "WM8-2")
    }

    // MARK: Kommentare aus Linear

    func testCommentsAreParsedNewestFirst() {
        let raw: [String: Any] = [
            "nodes": [
                ["id": "a", "body": "**Entscheidung · 15.11.2026, 15:55 Uhr**\n\nFrage", "createdAt": "2026-11-15T14:55:00.000Z",
                 "user": ["name": "Giuliano Costa"]],
                ["id": "b", "body": "**Abschluss · 15.11.2026, 17:33 Uhr · Lev**", "createdAt": "2026-11-15T16:33:00.000Z",
                 "parent": ["id": "a"]],
                ["body": "ohne id"],
            ],
            "pageInfo": ["hasNextPage": true],
        ]
        let comments = LinearTicketSource.comments(raw)
        XCTAssertEqual(comments.items.map(\.id), ["b", "a"])
        XCTAssertEqual(comments.items.map(\.kind), [.completion, .decision])
        XCTAssertEqual(comments.items[1].author, "Giuliano Costa")
        XCTAssertTrue(comments.items[0].isReply)
        XCTAssertTrue(comments.hasMore)
        XCTAssertEqual(TicketComment(id: "x", author: "", createdAt: nil, body: "Die Entscheidung steht", isReply: false).kind, .plain)
    }

    // MARK: Text

    func testDocumentIsSafeAndHighlightsDecisions() {
        let comments = TicketComments(items: [
            TicketComment(id: "1", author: "Lev", createdAt: nil, body: "**Abschluss · heute**\n\n- [ ] Handtest", isReply: false),
            TicketComment(id: "2", author: "Erika Beispiel", createdAt: nil,
                          body: "Bild: ![Bild](https://uploads.linear.app/x.png) und [Datei](file:///etc/passwd) und [Web](https://example.com) <script>x</script>",
                          isReply: false),
        ], hasMore: true)
        let text = TicketTextDocument.make(.init(title: "WM8-1 Titel", description: "## Ziel\nText", comments: .loaded(comments)))
        let plain = text.string
        XCTAssertTrue(plain.hasPrefix("WM8-1 Titel"))
        XCTAssertTrue(plain.contains("[Image in Linear]") || plain.contains("[Bild in Linear]"), plain)
        XCTAssertFalse(plain.contains("uploads.linear.app"), "Bildadressen werden nicht gezeigt oder geladen")
        XCTAssertTrue(plain.contains("<script>x</script>"), "HTML bleibt Text")
        var links: [URL] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        XCTAssertEqual(links, [URL(string: "https://example.com")!], "nur Links ins Web")
        XCTAssertTrue(plain.contains("◆ "), "Abschluss ist hervorgehoben")
        XCTAssertTrue(plain.contains("☐"))

        let loading = TicketTextDocument.make(.init(title: "T", description: "", comments: .loading)).string
        XCTAssertTrue(loading.contains("Loading comments") || loading.contains("Kommentare"))
    }

    /// Kosten des Textes für ein langes Ticket (Messwert für die Meldung, kein Budget-Test).
    func testDocumentCostForALongTicket() {
        let paragraph = "Ein Absatz mit **Fett**, `Code` und einem [Link](https://example.com), der etwas länger ist als eine Zeile."
        let description = (0..<200).map { $0 % 10 == 0 ? "## Abschnitt \($0)" : "- [ ] \(paragraph)" }.joined(separator: "\n")
        let comments = TicketComments(items: (0..<60).map {
            TicketComment(id: "\($0)", author: "Erika Beispiel", createdAt: Date(timeIntervalSince1970: 1_794_600_000),
                          body: (0..<15).map { _ in paragraph }.joined(separator: "\n\n"), isReply: false)
        }, hasMore: false)
        let input = TicketTextDocument.Input(title: "Langes Ticket", description: description, comments: .loaded(comments))
        let start = Date()
        let text = TicketTextDocument.make(input)
        let seconds = Date().timeIntervalSince(start)
        print("ticket-document: \(text.length) Zeichen in \(String(format: "%.1f", seconds * 1000)) ms")
        XCTAssertGreaterThan(text.length, 50_000)
        XCTAssertTrue(text.string.contains("Older comments are in Linear.") || text.string.contains("Ältere Kommentare"),
                      "mehr als 40 Kommentare: die ältesten stehen nur in Linear")

        // Was J/K auf dem Main Thread kostet: Text setzen und den sichtbaren
        // Teil layouten, eingebaut wie in der App (Scroll-Ansicht im Fenster).
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        let host = NSHostingView(rootView: TicketTextView(document: text, revision: 0, ticketKey: "A").frame(width: 800, height: 900))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 900)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let scroll = host.firstDescendant(of: NSScrollView.self), let textView = scroll.documentView as? NSTextView else {
            return XCTFail("keine Textansicht")
        }
        let small = TicketTextDocument.make(.init(title: "Kurz", description: "Text", comments: .loading))
        // Ein gewöhnliches Ticket: 40 Zeilen Beschreibung, 8 Kommentare.
        let typical = TicketTextDocument.make(.init(
            title: "Gewöhnlich", description: description.components(separatedBy: "\n").prefix(40).joined(separator: "\n"),
            comments: .loaded(TicketComments(items: Array(comments.items.prefix(8)), hasMore: false))))
        var samples: [String] = []
        for document in [small, text, typical, text, typical] {
            let begin = Date()
            textView.textStorage?.setAttributedString(document)
            textView.scroll(.zero)
            textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            scroll.layoutSubtreeIfNeeded()
            samples.append(String(format: "%.1f", Date().timeIntervalSince(begin) * 1000) + (document === text ? " lang" : document === typical ? " normal" : " kurz"))
        }
        print("ticket-set-text: " + samples.joined(separator: " / ") + " ms")
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for sub in subviews {
            if let hit = sub as? T { return hit }
            if let deeper = sub.firstDescendant(of: type) { return deeper }
        }
        return nil
    }
}
