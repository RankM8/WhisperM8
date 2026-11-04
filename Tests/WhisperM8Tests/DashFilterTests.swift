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
