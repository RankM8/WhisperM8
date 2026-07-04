import XCTest
@testable import WhisperM8

final class AgentReportTests: XCTestCase {
    private let fullReport = """
    {
      "status": "success",
      "summary": "Migration implementiert, 14 Tests gruen, committed.",
      "filesChanged": ["WhisperM8/Services/Dictation/OutputModeStore.swift"],
      "commits": [{"sha": "9c2e1af", "message": "feat(modes): Migration v2->v3"}],
      "testsRun": {"command": "swift test --filter OutputMode", "passed": true},
      "openQuestions": ["Legacy-Modes ohne Template auf Default mappen?"]
    }
    """

    func testParsesFullReport() throws {
        let report = try XCTUnwrap(AgentReport.parse(lastMessage: fullReport))
        XCTAssertEqual(report.status, .success)
        XCTAssertEqual(report.commits.first?.sha, "9c2e1af")
        XCTAssertEqual(report.testsRun?.passed, true)
        XCTAssertEqual(report.openQuestions.count, 1)
    }

    func testParsesReportWithNullTestsRun() throws {
        let json = """
        {"status": "partial", "summary": "s", "filesChanged": [], "commits": [], "testsRun": null, "openQuestions": []}
        """
        let report = try XCTUnwrap(AgentReport.parse(lastMessage: json))
        XCTAssertEqual(report.status, .partial)
        XCTAssertNil(report.testsRun)
    }

    /// Modelle wrappen JSON gern in Markdown-Fences — muss trotzdem parsen.
    func testParsesFencedReport() throws {
        let fenced = "```json\n\(fullReport)\n```"
        let report = try XCTUnwrap(AgentReport.parse(lastMessage: fenced))
        XCTAssertEqual(report.status, .success)
    }

    func testNonJSONYieldsNil() {
        XCTAssertNil(AgentReport.parse(lastMessage: "Ich bin fertig, alles gut!"))
    }

    func testUnknownStatusYieldsNil() {
        let json = """
        {"status": "great", "summary": "s", "filesChanged": [], "commits": [], "testsRun": null, "openQuestions": []}
        """
        XCTAssertNil(AgentReport.parse(lastMessage: json))
    }

    func testRoundTrip() throws {
        let report = try XCTUnwrap(AgentReport.parse(lastMessage: fullReport))
        let encoded = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(AgentReport.self, from: encoded)
        XCTAssertEqual(decoded, report)
    }

    /// Das eingebettete Schema muss selbst gültiges JSON sein — sonst lehnt
    /// codex den --output-schema-Aufruf ab.
    func testSchemaStringIsValidJSON() throws {
        let data = try XCTUnwrap(CodexReportSchema.json.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "object")
        XCTAssertNotNil((object?["properties"] as? [String: Any])?["status"])
    }

    func testStripCodeFenceLeavesPlainTextUntouched() {
        XCTAssertEqual(AgentReport.stripCodeFence("{\"a\":1}"), "{\"a\":1}")
    }
}
