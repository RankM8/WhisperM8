import XCTest
@testable import WhisperM8

final class DashFilterTests: XCTestCase {
    func testSpacedEmDashBecomesComma() {
        XCTAssertEqual(DashFilter.apply("Das ist gut — aber teuer."), "Das ist gut, aber teuer.")
    }

    func testGermanEnDashBecomesComma() {
        XCTAssertEqual(DashFilter.apply("Ich melde mich – versprochen."), "Ich melde mich, versprochen.")
    }

    func testUnspacedEnglishEmDashBecomesComma() {
        XCTAssertEqual(DashFilter.apply("It works—mostly."), "It works, mostly.")
    }

    func testParentheticalPairBecomesCommas() {
        XCTAssertEqual(
            DashFilter.apply("Das Modell — ein großes — ist schnell."),
            "Das Modell, ein großes, ist schnell."
        )
    }

    func testDashBeforePunctuationOrLineEndDisappears() {
        XCTAssertEqual(DashFilter.apply("Fertig —."), "Fertig.")
        XCTAssertEqual(DashFilter.apply("Erste Zeile —\nZweite Zeile"), "Erste Zeile\nZweite Zeile")
    }

    func testDashAfterCommaDoesNotDoubleTheComma() {
        XCTAssertEqual(DashFilter.apply("Ja, — klar."), "Ja, klar.")
    }

    func testNumberRangesBecomeHyphens() {
        XCTAssertEqual(DashFilter.apply("Von 10–12 Uhr, 2025 — 2026"), "Von 10-12 Uhr, 2025-2026")
    }

    func testUnspacedEnDashBetweenWordsBecomesHyphen() {
        XCTAssertEqual(DashFilter.apply("Die Ost–West-Achse"), "Die Ost-West-Achse")
    }

    func testDashBulletsBecomeHyphenBullets() {
        XCTAssertEqual(DashFilter.apply("— Punkt eins\n  – Punkt zwei"), "- Punkt eins\n  - Punkt zwei")
    }

    func testCodeStaysUntouched() {
        let input = "Siehe `a — b` hier — fertig.\n```\nlet x = \"—\"\n```\nEnde — gut."
        let expected = "Siehe `a — b` hier, fertig.\n```\nlet x = \"—\"\n```\nEnde, gut."
        XCTAssertEqual(DashFilter.apply(input), expected)
    }

    func testTextWithoutDashesIsUnchanged() {
        let input = "Ein ganz normaler Satz mit Bindestrich-Wort und - Aufzählung."
        XCTAssertEqual(DashFilter.apply(input), input)
    }

    // MARK: - Striche, die keine Gedankenstriche sind (Review D9)

    func testMinusBeforeDigitStays() {
        XCTAssertEqual(DashFilter.apply("Temperatur –5 Grad — kalt."), "Temperatur –5 Grad, kalt.")
        XCTAssertEqual(DashFilter.apply("–5 °C am Morgen"), "–5 °C am Morgen")
        // Mit Zahl davor bleibt es ein Bereich.
        XCTAssertEqual(DashFilter.apply("Von 3–5 Uhr"), "Von 3-5 Uhr")
    }

    func testPriceDashStays() {
        XCTAssertEqual(DashFilter.apply("Kostet 49,– € — fair."), "Kostet 49,– €, fair.")
        XCTAssertEqual(DashFilter.apply("Preis: 12.–"), "Preis: 12.–")
    }

    func testTablePlaceholderCellStays() {
        let input = "| Name | Wert |\n|---|---|\n| A | — |\n| B | – | x — y |"
        let expected = "| Name | Wert |\n|---|---|\n| A | — |\n| B | – | x, y |"
        XCTAssertEqual(DashFilter.apply(input), expected)
    }

    func testTildeFenceAndIndentedCodeStayUntouched() {
        let input = "Vorher — gut.\n~~~\nlet x = \"—\"\n```\nnoch Code —\n~~~\n\n    let y = a — b\n    z — 1\nDanach — auch."
        let expected = "Vorher, gut.\n~~~\nlet x = \"—\"\n```\nnoch Code —\n~~~\n\n    let y = a — b\n    z — 1\nDanach, auch."
        XCTAssertEqual(DashFilter.apply(input), expected)
    }

    func testIndentedListItemIsNotCode() {
        XCTAssertEqual(DashFilter.apply("Liste:\n\n    – Punkt"), "Liste:\n\n    - Punkt")
    }

    func testSentenceStartingWithDashIsNoBullet() {
        XCTAssertEqual(DashFilter.apply("Das war knapp.\n— Und dann kam er doch."), "Das war knapp.\nUnd dann kam er doch.")
        XCTAssertEqual(DashFilter.apply("— Einzelner Satz."), "Einzelner Satz.")
        // Nach einem Doppelpunkt ist es eine Liste, auch mit nur einem Punkt.
        XCTAssertEqual(DashFilter.apply("Zutaten:\n— Mehl"), "Zutaten:\n- Mehl")
    }

    func testDictationKeepsDashesOfSelectionInCorrectAndRephrase() async throws {
        let selection = TranscriptContextBundle(
            selectedText: SelectedContext(text: "Kurz — und gut", sourceAppName: "Mail", sourceBundleIdentifier: nil)
        )
        for modeID in [OutputMode.correctID, OutputMode.rephraseID] {
            let service = PostProcessingService(processor: MockPostProcessor(output: "Kurz — und gut."))
            let output = try await service.process(
                rawText: "", mode: OutputMode.mode(for: modeID), language: "de", contextBundle: selection
            )
            XCTAssertEqual(output, "Kurz — und gut.", modeID)
        }
        // Andere Modi nutzen die Markierung nur als Kontext: Filter bleibt.
        let slack = PostProcessingService(processor: MockPostProcessor(output: "Klar — mache ich."))
        let slackOutput = try await slack.process(
            rawText: "", mode: OutputMode.mode(for: OutputMode.slackID), language: "de", contextBundle: selection
        )
        XCTAssertEqual(slackOutput, "Klar, mache ich.")
        // Ohne Striche in der Markierung filtert auch Korrigieren.
        let plain = PostProcessingService(processor: MockPostProcessor(output: "Kurz — und gut."))
        let plainOutput = try await plain.process(
            rawText: "",
            mode: OutputMode.mode(for: OutputMode.correctID),
            language: "de",
            contextBundle: TranscriptContextBundle(selectedText: SelectedContext(text: "Kurz und gut", sourceAppName: nil, sourceBundleIdentifier: nil))
        )
        XCTAssertEqual(plainOutput, "Kurz, und gut.")
    }

    func testPromptTellsModelToKeepDashesOfSelectionWhenDictating() {
        let mode = OutputMode.mode(for: OutputMode.correctID)
        let builder = PromptPackageBuilder()
        let withDashes = TranscriptContextBundle(
            selectedText: SelectedContext(text: "A — B", sourceAppName: nil, sourceBundleIdentifier: nil)
        )
        XCTAssertNotNil(builder.selectionDashesBlock(mode: mode, contextBundle: withDashes))
        XCTAssertNil(builder.selectionDashesBlock(mode: mode, contextBundle: .empty))
        XCTAssertNil(builder.selectionDashesBlock(mode: OutputMode.mode(for: OutputMode.slackID), contextBundle: withDashes))
    }

    func testPostProcessingOutputIsFiltered() async throws {
        let service = PostProcessingService(processor: MockPostProcessor(output: "Klar — mache ich."))
        let output = try await service.process(
            rawText: "raw",
            mode: OutputMode.mode(for: OutputMode.slackID),
            language: "de"
        )
        XCTAssertEqual(output, "Klar, mache ich.")
    }

    func testGlobalContractForbidsDashesAndTemplatesUseNone() {
        let package = PromptPackageBuilder().build(
            rawText: "Schreib das besser.",
            mode: OutputMode.mode(for: OutputMode.taskID),
            template: PostProcessingTemplate.builtInTemplate(id: PostProcessingTemplate.taskID)!,
            language: "de",
            contextBundle: .empty
        )
        XCTAssertTrue(package.prompt.contains("Never use em dashes"))

        // Die Vorlagen selbst dürfen keine Gedankenstriche vormachen.
        for template in PostProcessingTemplate.builtInTemplates {
            XCTAssertFalse(template.instruction.contains("\u{2014}"), template.id)
            XCTAssertFalse(template.instruction.contains("\u{2013}"), template.id)
        }
    }
}
