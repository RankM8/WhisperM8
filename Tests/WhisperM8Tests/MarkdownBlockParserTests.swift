import XCTest
@testable import WhisperM8

final class MarkdownBlockParserTests: XCTestCase {

    func testPlainTextIsSingleParagraph() {
        XCTAssertEqual(MarkdownBlockParser.parse("Nur ein Satz."), [.paragraph("Nur ein Satz.")])
    }

    func testBlankLineSplitsParagraphs() {
        let blocks = MarkdownBlockParser.parse("Absatz eins.\n\nAbsatz zwei.")
        XCTAssertEqual(blocks, [.paragraph("Absatz eins."), .paragraph("Absatz zwei.")])
    }

    func testSoftWrappedParagraphKeepsLines() {
        let blocks = MarkdownBlockParser.parse("Zeile eins\nZeile zwei")
        XCTAssertEqual(blocks, [.paragraph("Zeile eins\nZeile zwei")])
    }

    func testHeadings() {
        let blocks = MarkdownBlockParser.parse("## Fazit LM8-UI-01\n\nText")
        XCTAssertEqual(blocks[0], .heading(level: 2, text: "Fazit LM8-UI-01"))
        XCTAssertEqual(blocks[1], .paragraph("Text"))
    }

    func testHashWithoutSpaceIsNotHeading() {
        XCTAssertEqual(MarkdownBlockParser.parse("#22c55e ist ein Grün"), [.paragraph("#22c55e ist ein Grün")])
    }

    func testCodeFenceWithLanguage() {
        let blocks = MarkdownBlockParser.parse("```swift\nlet x = 1\nlet y = 2\n```\nDanach")
        XCTAssertEqual(blocks[0], .codeFence(language: "swift", code: "let x = 1\nlet y = 2"))
        XCTAssertEqual(blocks[1], .paragraph("Danach"))
    }

    func testUnclosedFenceKeepsContent() {
        let blocks = MarkdownBlockParser.parse("Text\n```\nnoch offen")
        XCTAssertEqual(blocks, [.paragraph("Text"), .codeFence(language: nil, code: "noch offen")])
    }

    func testUnorderedList() {
        let blocks = MarkdownBlockParser.parse("- eins\n- zwei\n* drei")
        XCTAssertEqual(blocks, [.list(items: ["eins", "zwei", "drei"], ordered: false)])
    }

    func testOrderedList() {
        let blocks = MarkdownBlockParser.parse("1. erstens\n2. zweitens")
        XCTAssertEqual(blocks, [.list(items: ["erstens", "zweitens"], ordered: true)])
    }

    func testListContinuationLineJoinsItem() {
        let blocks = MarkdownBlockParser.parse("- ein Item\n  mit Fortsetzung")
        XCTAssertEqual(blocks, [.list(items: ["ein Item\nmit Fortsetzung"], ordered: false)])
    }

    func testOrderedAndUnorderedDontMerge() {
        let blocks = MarkdownBlockParser.parse("- bullet\n1. nummer")
        XCTAssertEqual(blocks, [
            .list(items: ["bullet"], ordered: false),
            .list(items: ["nummer"], ordered: true),
        ])
    }

    func testQuote() {
        let blocks = MarkdownBlockParser.parse("> zitiert\n> weiter")
        XCTAssertEqual(blocks, [.quote("zitiert\nweiter")])
    }

    func testTableKeptAsMonospaceBlock() {
        let table = "| a | b |\n|---|---|\n| 1 | 2 |"
        XCTAssertEqual(MarkdownBlockParser.parse(table), [.table(table)])
    }

    func testDivider() {
        XCTAssertEqual(MarkdownBlockParser.parse("oben\n\n---\n\nunten"), [
            .paragraph("oben"), .divider, .paragraph("unten"),
        ])
    }

    func testDashLineWithTextIsNotDivider() {
        XCTAssertEqual(MarkdownBlockParser.parse("--- fast ein Divider"), [.paragraph("--- fast ein Divider")])
    }

    func testMixedDocument() {
        let doc = """
        Läuft end-to-end. Verifiziert:

        - **Light + Dark** ✓
        - **Dots + Pills** ✓

        ## Fazit

        ```bash
        npm run typecheck
        ```

        Was davon?
        """
        let blocks = MarkdownBlockParser.parse(doc)
        XCTAssertEqual(blocks.count, 5)
        XCTAssertEqual(blocks[0], .paragraph("Läuft end-to-end. Verifiziert:"))
        XCTAssertEqual(blocks[1], .list(items: ["**Light + Dark** ✓", "**Dots + Pills** ✓"], ordered: false))
        XCTAssertEqual(blocks[2], .heading(level: 2, text: "Fazit"))
        XCTAssertEqual(blocks[3], .codeFence(language: "bash", code: "npm run typecheck"))
        XCTAssertEqual(blocks[4], .paragraph("Was davon?"))
    }

    func testEmptyStringYieldsNoBlocks() {
        XCTAssertTrue(MarkdownBlockParser.parse("").isEmpty)
    }
}

final class MarkdownTableTests: XCTestCase {

    func testParsesHeaderAndRows() {
        let table = MarkdownTable.parse("| Ticket | Ergebnis |\n|---|---|\n| AKQ-84 | ✓ Bestanden |\n| AKQ-115 | ⚠ Mängel |")
        XCTAssertEqual(table?.headers, ["Ticket", "Ergebnis"])
        XCTAssertEqual(table?.rows, [["AKQ-84", "✓ Bestanden"], ["AKQ-115", "⚠ Mängel"]])
    }

    func testTableWithoutSeparatorHasNoHeaders() {
        let table = MarkdownTable.parse("| a | b |\n| c | d |")
        XCTAssertEqual(table?.headers, [])
        XCTAssertEqual(table?.rows, [["a", "b"], ["c", "d"]])
    }

    func testPadsShortRowsToColumnCount() {
        let table = MarkdownTable.parse("| a | b | c |\n|---|---|---|\n| nur-eine |")
        XCTAssertEqual(table?.rows, [["nur-eine", "", ""]])
    }

    func testAlignmentColonsCountAsSeparator() {
        let table = MarkdownTable.parse("| L | R |\n|:--|--:|\n| 1 | 2 |")
        XCTAssertEqual(table?.headers, ["L", "R"])
        XCTAssertEqual(table?.rows, [["1", "2"]])
    }

    func testGarbageYieldsNil() {
        XCTAssertNil(MarkdownTable.parse("kein pipe inhalt"))
    }
}
