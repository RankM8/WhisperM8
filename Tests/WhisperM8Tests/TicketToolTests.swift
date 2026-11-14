import XCTest
@testable import WhisperM8

/// Pure Bausteine des Ticket-Werkzeugs: Kästchen, fester Aufbau der Kommentare,
/// Ordnung, Tabelle der Bereiche.
final class TicketToolTests: XCTestCase {
    private let sample = """
    **Stand 14.11.2026:** offen.

    ## Ziel
    Text mit einem Kästchen, das nicht zählt:
    - [ ] nur ein Beispiel

    ## Fertig, wenn

    - [ ] Board mit drei Spalten steht
    - [x] die Karte den Chat zeigt
    * [ ] das Detail „Zum Chat“ anbietet
      - [X] eingerückt geht auch

    ## Hinweise
    - [ ] gehört nicht mehr dazu
    """

    // MARK: Kästchen

    func testItemsComeFromTheCriteriaSection() {
        let items = TicketChecklist.items(in: sample)
        XCTAssertEqual(items.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(items.map(\.isDone), [false, true, false, true])
        XCTAssertEqual(items[2].text, "das Detail „Zum Chat“ anbietet")
        XCTAssertEqual(TicketChecklist.progress(in: sample), TicketChecklistProgress(done: 2, total: 4))
        XCTAssertTrue(TicketChecklist.hasSection(sample))
    }

    func testHeadingVariantsAndFallbackToAllBoxes() {
        for heading in ["## Fertig, wenn:", "### **Fertig, wenn**", "# Done when", "## Acceptance criteria"] {
            let text = "\(heading)\n- [ ] eins\n# Weiter\n- [ ] zwei"
            XCTAssertEqual(TicketChecklist.items(in: text).map(\.text), ["eins"], heading)
        }
        XCTAssertEqual(TicketChecklist.items(in: "## **Fertig, wenn:**\n- [ ] eins\n## Weiter\n- [ ] zwei").map(\.text), ["eins"],
                       "fett und mit Doppelpunkt")
        let fenced = "## Fertig, wenn\n- [ ] eins\n```sh\n# alles bauen\n- [ ] kein Kästchen\n```\n- [ ] zwei\n## Hinweise\n- [ ] drei"
        XCTAssertEqual(TicketChecklist.items(in: fenced).map(\.text), ["eins", "zwei"],
                       "im Codeblock ist `#` keine Überschrift und `- [ ]` kein Kästchen")
        let nested = "## Fertig, wenn\n- [ ] eins\n### Später\n- [ ] zwei\n## Hinweise\n- [ ] drei"
        XCTAssertEqual(TicketChecklist.items(in: nested).map(\.text), ["eins", "zwei"], "Unterabschnitte gehören dazu")
        let without = "Text\n- [ ] eins\n- [x] zwei"
        XCTAssertFalse(TicketChecklist.hasSection(without))
        XCTAssertEqual(TicketChecklist.items(in: without).count, 2, "ohne Abschnitt zählen alle Kästchen")
        XCTAssertNil(TicketChecklist.progress(in: "## Fertig, wenn\nnur Text"))
        XCTAssertTrue(TicketChecklist.hasSection("## Fertig, wenn\nnur Text"), "Abschnitt da, auch ohne Kästchen")
        XCTAssertFalse(TicketChecklist.hasSection("Fertig, wenn alles geht"), "ein Satz ist keine Überschrift")
    }

    func testSettingChangesOnlyTheNamedBoxes() throws {
        let result = try TicketChecklist.setting(["1", "detail"], done: true, in: sample)
        XCTAssertEqual(result.changed.map(\.number), [1, 3])
        let lines = sample.components(separatedBy: "\n"), changed = result.description.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, changed.count)
        let different = zip(lines, changed).filter { $0 != $1 }
        XCTAssertEqual(different.count, 2, "sonst bleibt jede Zeile, wie sie war")
        XCTAssertTrue(changed.contains("- [x] Board mit drei Spalten steht"))
        XCTAssertTrue(changed.contains("* [x] das Detail „Zum Chat“ anbietet"), "das Listenzeichen bleibt")
        XCTAssertTrue(changed.contains("- [ ] nur ein Beispiel"), "Kästchen außerhalb des Abschnitts bleiben")
        XCTAssertEqual(TicketChecklist.progress(in: result.description), TicketChecklistProgress(done: 4, total: 4))

        let again = try TicketChecklist.setting(["1"], done: true, in: result.description)
        XCTAssertTrue(again.changed.isEmpty, "schon abgehakt: nichts geändert")
        XCTAssertEqual(again.description, result.description)

        let reopened = try TicketChecklist.setting(["4"], done: false, in: sample)
        XCTAssertTrue(reopened.description.contains("  - [ ] eingerückt geht auch"), "Einrückung bleibt")
    }

    func testReferencesMustBeUnambiguous() {
        XCTAssertThrowsError(try TicketChecklist.setting(["9"], done: true, in: sample)) {
            XCTAssertEqual($0 as? TicketChecklist.Failure, .notFound("9"))
        }
        XCTAssertThrowsError(try TicketChecklist.setting(["gibt es nicht"], done: true, in: sample)) {
            XCTAssertEqual($0 as? TicketChecklist.Failure, .notFound("gibt es nicht"))
        }
        XCTAssertThrowsError(try TicketChecklist.setting(["d"], done: true, in: sample)) { error in
            guard case TicketChecklist.Failure.ambiguous("d", let hits) = error else { return XCTFail("\(error)") }
            XCTAssertGreaterThan(hits.count, 1)
        }
        XCTAssertThrowsError(try TicketChecklist.setting(["1"], done: true, in: "ohne Kästchen")) {
            XCTAssertEqual($0 as? TicketChecklist.Failure, .noItems)
        }
        for odd in ["0", "+1", "-1", "", "  "] {
            XCTAssertThrowsError(try TicketChecklist.setting([odd], done: true, in: "- [ ] eins\n- [ ] zwei"), "„\(odd)“ ist keine Nummer")
        }
        // Der ganze Text eines Kästchens gewinnt gegen ein anderes, das ihn nur enthält.
        let twins = "- [ ] Board\n- [ ] Board mit Filtern"
        XCTAssertEqual(try TicketChecklist.setting(["board"], done: true, in: twins).changed.map(\.number), [1])
    }

    // MARK: Entscheidung und Abschluss

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        return calendar
    }

    private var date: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 5, minute: 15))! }

    func testDecisionHasTheFixedShape() {
        let body = TicketRecordText.decision(
            .init(question: "Wo lebt\ndie Ansicht?", options: ["Umschalter im Fenster", "eigenes Fenster"],
                  chosen: "Umschalter im Fenster", by: "Giuliano Costa", note: nil),
            at: date, calendar: calendar)
        XCTAssertEqual(body, """
        **Entscheidung · 14.11.2026, 05:15 Uhr**

        **Frage:** Wo lebt die Ansicht?

        **Möglichkeiten:**
        * Umschalter im Fenster
        * eigenes Fenster

        **Gewählt:** Umschalter im Fenster

        **Entschieden von:** Giuliano Costa
        """)
        let withNote = TicketRecordText.decision(
            .init(question: "F", options: ["a", "b"], chosen: "a", by: "G", note: "gilt bis Stufe 2"), at: date, calendar: calendar)
        XCTAssertTrue(withNote.hasSuffix("**Anmerkung:** gilt bis Stufe 2"))
    }

    func testCompletionListsOnlyWhatWasGiven() {
        let full = TicketRecordText.completion(
            .init(chat: "Jon", built: "Schalter und Einstellungen", commit: "dfda8d7c", notIncluded: "die Ansicht selbst",
                  testSteps: ["Schalter an", "Key eintragen"], imageURL: "https://uploads.linear.app/x/bild.png"),
            at: date, calendar: calendar)
        XCTAssertEqual(full, """
        **Abschluss · 14.11.2026, 05:15 Uhr · Jon**

        **Gebaut:** Schalter und Einstellungen

        **Commit:** dfda8d7c

        **Nicht Teil davon:** die Ansicht selbst

        **Handtest:**
        - [ ] Schalter an
        - [ ] Key eintragen

        ![Bild](https://uploads.linear.app/x/bild.png)
        """)
        let short = TicketRecordText.completion(.init(chat: "Jon", built: "Analyse"), at: date, calendar: calendar)
        XCTAssertEqual(short, "**Abschluss · 14.11.2026, 05:15 Uhr · Jon**\n\n**Gebaut:** Analyse")
    }

    // MARK: Ordnung

    func testHygieneFindsWhatNeedsALook() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let criteria = "## Fertig, wenn\n- [ ] x"
        let chat = UUID()
        let old = now.addingTimeInterval(-22 * 86_400), fresh = now.addingTimeInterval(-20 * 86_400)
        let tickets = [
            TicketFixtures.ticket(1, status: "In Progress", description: criteria, links: [TicketFixtures.link(chat)], updatedAt: fresh),
            TicketFixtures.ticket(2, status: "In Progress", description: criteria, updatedAt: fresh),                       // nie ein Chat
            TicketFixtures.ticket(3, status: "Merge-bereit", description: criteria, links: [TicketFixtures.link(chat, active: false)]),  // abgegeben
            TicketFixtures.ticket(4, status: "Todo", description: "ohne Abschnitt", updatedAt: old),
            TicketFixtures.ticket(5, status: "Backlog", description: "", project: nil, updatedAt: old),
            TicketFixtures.ticket(6, status: "Done", description: "", project: nil, updatedAt: old),
        ]
        let findings = TicketHygiene.findings(in: tickets, now: now)
        XCTAssertEqual(findings, [
            TicketHygieneFinding(kind: .noProject, keys: ["WM8-5"]),
            TicketHygieneFinding(kind: .noCriteria, keys: ["WM8-4"]),
            TicketHygieneFinding(kind: .startedWithoutChat, keys: ["WM8-2"]),
            TicketHygieneFinding(kind: .stale, keys: ["WM8-4"]),
        ], "Backlog darf liegen und braucht noch keine Kästchen; Erledigtes zählt nie; ein abgegebenes Ticket wartet nicht auf einen Chat")
        XCTAssertTrue(TicketHygiene.findings(in: [tickets[0]], now: now).isEmpty)
        // Kästchen ohne die Überschrift genügen, und ein Ticket ohne Zeitangabe gilt nicht als liegengeblieben.
        let loose = TicketFixtures.ticket(7, status: "Todo", description: "- [ ] ein Punkt")
        XCTAssertTrue(TicketHygiene.findings(in: [loose], now: now).isEmpty)
    }

    // MARK: Tabelle der Bereiche

    private let table = """
    Text davor.

    | Zweck | Befehl |
    |---|---|
    | etwas | `x` |

    | Bereich | Ordner | Linear-Projekt |
    |:---|---|---|
    | Diktat | `docs/features/dictation`, `docs/features/voice-gate.md` | Diktat |
    | Tickets | [tickets.md](docs/features/tickets.md) | Tickets |
    | Ohne Doku | – | Werkzeuge |

    Text danach.
    """

    func testAreasTableIsFoundByItsColumns() {
        let areas = TicketAreasTable.parse(table)
        XCTAssertEqual(areas, [
            TicketArea(area: "Diktat", paths: ["docs/features/dictation", "docs/features/voice-gate.md"], project: "Diktat"),
            TicketArea(area: "Tickets", paths: ["docs/features/tickets.md"], project: "Tickets"),
            TicketArea(area: "Ohne Doku", paths: [], project: "Werkzeuge"),
        ], "die erste Tabelle hat keine Spalten Ordner und Projekt und zählt nicht; bei einem Link zählt das Ziel")
        XCTAssertNil(TicketAreasTable.parse("| Zweck | Befehl |\n|---|---|\n| a | b |"))
    }

    func testAreasAreCheckedAgainstProjectsAndFolders() {
        let areas = TicketAreasTable.parse(table)!
        let findings = TicketAreasTable.findings(areas: areas, projects: ["Diktat", "werkzeuge", "Controller"]) { path in
            path == "docs/features/dictation"
        }
        XCTAssertEqual(findings, [
            "Projekt „Controller“ steht nicht in der Tabelle",
            "Doku fehlt: docs/features/voice-gate.md (Diktat)",
            "„Tickets“ steht in der Tabelle, aber nicht im Ticket-Werkzeug",
            "Doku fehlt: docs/features/tickets.md (Tickets)",
            "Projekt „Werkzeuge“ hat keinen Doku-Ordner",
        ])
        let fine = TicketAreasTable.findings(areas: [areas[0]], projects: ["Diktat"]) { _ in true }
        XCTAssertTrue(fine.isEmpty)
    }

    /// Die Tabelle dieses Projekts in `docs/features/tickets.md`: lesbar, und
    /// jede genannte Doku gibt es. `tickets doctor` prüft dasselbe gegen Linear.
    func testThisProjectsAreasTableIsReadableAndItsDocsExist() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("docs/features/tickets.md"), encoding: .utf8)
        let areas = try XCTUnwrap(TicketAreasTable.parse(text), "Tabelle Bereich, Ordner, Linear-Projekt fehlt")
        XCTAssertGreaterThanOrEqual(areas.count, 11)
        XCTAssertEqual(Set(areas.map(\.project)).count, areas.count, "jedes Projekt steht einmal da")
        let findings = TicketAreasTable.findings(areas: areas, projects: areas.map(\.project)) { path in
            FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
        }
        XCTAssertEqual(findings, [])
    }

    func testOnlyImagesAreUploaded() {
        XCTAssertEqual(TicketImage.contentType(forPath: "/tmp/Bild.PNG"), "image/png")
        XCTAssertEqual(TicketImage.contentType(forPath: "a.jpeg"), "image/jpeg")
        XCTAssertNil(TicketImage.contentType(forPath: "verlauf.jsonl"))
        XCTAssertNil(TicketImage.contentType(forPath: "ohne-endung"))
        XCTAssertTrue(TicketImage.looksLike("image/png", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])))
        XCTAssertTrue(TicketImage.looksLike("image/jpeg", Data([0xFF, 0xD8, 0xFF, 0xE0])))
        XCTAssertTrue(TicketImage.looksLike("image/gif", Data("GIF89a".utf8)))
        XCTAssertTrue(TicketImage.looksLike("image/webp", Data("RIFF".utf8) + Data([1, 2, 3, 4]) + Data("WEBP".utf8)))
        XCTAssertFalse(TicketImage.looksLike("image/png", Data("{\"type\":\"user\"}".utf8)), "ein umbenannter Verlauf ist kein Bild")
        XCTAssertFalse(TicketImage.looksLike("image/png", Data([0xFF, 0xD8, 0xFF])), "Endung und Inhalt müssen zusammenpassen")
    }
}
