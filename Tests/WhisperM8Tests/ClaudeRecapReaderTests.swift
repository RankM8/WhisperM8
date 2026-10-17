import XCTest
@testable import WhisperM8

final class ClaudeRecapReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("recap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func recapLine(_ text: String, at timestamp: String) -> String {
        let object: [String: Any] = ["type": "system", "subtype": "away_summary", "content": text,
                                     "timestamp": timestamp, "uuid": UUID().uuidString]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func write(_ lines: [String]) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let userLine = #"{"type":"user","message":{"role":"user","content":"away_summary steht hier nur im Text"}}"#
    private let assistantLine = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}"#

    func testReadsNewestFirstAndRespectsLimit() throws {
        let url = try write([
            recapLine("Ziel A. Zuletzt eins.", at: "2026-10-17T10:00:00.000Z"),
            userLine,
            recapLine("Ziel A. Zuletzt zwei.", at: "2026-10-17T11:00:00.000Z"),
            assistantLine,
            recapLine("Ziel A. Zuletzt drei.", at: "2026-10-17T12:00:00.000Z"),
            recapLine("Ziel A. Zuletzt vier. (disable recaps in /config)", at: "2026-10-17T13:00:00.000Z"),
        ])
        let recaps = ClaudeRecapReader.recaps(fileURL: url)
        XCTAssertEqual(recaps.map(\.text), ["Ziel A. Zuletzt vier.", "Ziel A. Zuletzt drei.", "Ziel A. Zuletzt zwei."],
                       "neueste zuerst, höchstens drei, Abschalt-Hinweis entfernt")
        XCTAssertEqual(recaps.first?.at, ISO8601DateFormatter().date(from: "2026-10-17T13:00:00Z"))
        XCTAssertEqual(ClaudeRecapReader.recaps(fileURL: url, limit: 1).count, 1)
        XCTAssertEqual(ClaudeRecapReader.recaps(fileURL: url, limit: 0), [])
    }

    func testIgnoresLookalikesBrokenLinesAndEmptyContent() {
        XCTAssertNil(ClaudeRecapReader.recap(fromLine: userLine), "das Wort im Text macht noch keinen Rückblick")
        XCTAssertNil(ClaudeRecapReader.recap(fromLine: #"{"type":"system","subtype":"away_summary""#), "abgeschnitten")
        XCTAssertNil(ClaudeRecapReader.recap(fromLine: #"{"type":"system","subtype":"away_summary","content":"  "}"#))
        XCTAssertNil(ClaudeRecapReader.recap(fromLine: #"{"type":"system","subtype":"compact_boundary","content":"x"}"#))
        XCTAssertNil(ClaudeRecapReader.recap(fromLine: #"{"type":"system","subtype":"away_summary","content":42}"#))
    }

    func testMissingOrOddTimestampKeepsTheText() {
        let recap = ClaudeRecapReader.recap(
            fromLine: #"{"type":"system","subtype":"away_summary","content":"Ziel B.","timestamp":"gestern"}"#)
        XCTAssertEqual(recap, ClaudeRecap(at: nil, text: "Ziel B."))
        let plain = ClaudeRecapReader.recap(
            fromLine: #"{"type":"system","subtype":"away_summary","content":"Ziel C.","timestamp":"2026-10-17T13:00:00Z"}"#)
        XCTAssertNotNil(plain?.at, "auch ohne Sekundenbruchteile")
    }

    func testFindsRecapsFarBehindTheEndAndRespectsTheScanLimit() throws {
        // Wie im Feld: der jüngste Rückblick liegt hinter viel Tool-Ausgabe.
        let filler = (0..<300).map { _ in assistantLine }
        let url = try write([recapLine("Weit hinten", at: "2026-10-17T09:00:00.000Z")] + filler)
        XCTAssertEqual(ClaudeRecapReader.recaps(fileURL: url, chunkBytes: 1_024).map(\.text), ["Weit hinten"],
                       "kleine Blöcke: die Suche läuft über viele Blockgrenzen")
        XCTAssertEqual(ClaudeRecapReader.recaps(fileURL: url, maxScanBytes: 2_000, chunkBytes: 512), [],
                       "weiter als das Suchlimit wird nicht zurückgegangen")
    }

    func testMarkerAcrossABlockBoundaryIsFoundExactlyOnce() throws {
        let line = recapLine("Über der Grenze", at: "2026-10-17T09:00:00.000Z")
        let url = try write([line, assistantLine])
        let fileSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        // Jede Blockgröße legt die Grenze an eine andere Stelle — auch mitten ins Merkmal.
        for chunk in stride(from: 7, through: fileSize, by: 13) {
            XCTAssertEqual(ClaudeRecapReader.recaps(fileURL: url, limit: 5, chunkBytes: chunk).map(\.text),
                           ["Über der Grenze"], "Blockgröße \(chunk)")
        }
    }

    func testHugeLinesAreSkippedAndQuotedMarkersDoNotCount() throws {
        let huge = String(repeating: "y", count: ClaudeRecapReader.maxLineBytes * 2)
        let quoted = #"{"type":"user","message":{"content":"zitiert: \"subtype\":\"away_summary\" \#(huge)"}}"#
        let url = try write([recapLine("Echt", at: "2026-10-17T09:00:00.000Z"), quoted,
                             #"{"type":"assistant","x":"\#(huge)"}"#])
        XCTAssertEqual(ClaudeRecapReader.recaps(fileURL: url, chunkBytes: 4_096).map(\.text), ["Echt"])
    }

    func testMissingFileOrTranscriptWithoutRecapsIsEmpty() throws {
        XCTAssertEqual(ClaudeRecapReader.recaps(fileURL: directory.appendingPathComponent("fehlt.jsonl")), [])
        XCTAssertEqual(ClaudeRecapReader.recaps(fileURL: try write([userLine, assistantLine])), [])
    }
}

final class ChatsRecapOutputTests: XCTestCase {
    private let id = UUID(uuidString: "C0FFEE00-0000-0000-0000-000000000001")!
    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func entry(_ provider: AgentProvider) -> ChatsSessionEntry {
        ChatsSessionEntry(
            session: AgentChatSession(id: id, provider: provider, projectID: UUID(), title: "Intro-Qualität",
                                      status: .running, groupName: nil, lastActivityAt: now,
                                      titleIsAutoGenerated: nil, lastTurnAt: nil, kind: nil),
            projectName: "ListM8", projectPath: "/p/ListM8")
    }

    func testParseShowRecapFlag() throws {
        let options = try ChatsCLIParser.parseShow(["kai", "--recap", "--json"])
        XCTAssertEqual(options, ChatsShowOptions(ref: "kai", all: false, json: true, recap: true))
        XCTAssertFalse(try ChatsCLIParser.parseShow(["kai"]).recap)
    }

    func testJSONListsRecapsNewestFirstWithoutNote() throws {
        let recaps = [ClaudeRecap(at: now.addingTimeInterval(-120), text: "Ziel ist X."),
                      ClaudeRecap(at: nil, text: "Ziel war Y.")]
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(ChatsOutput.encodeJSON(ChatsRecapOutput.json(entry: entry(.claude), recaps: recaps, now: now)).utf8))
            as? [String: Any])
        XCTAssertEqual(json["ref"] as? String, "c0ffee00")
        XCTAssertEqual(json["provider"] as? String, "claude")
        XCTAssertNil(json["note"])
        let list = try XCTUnwrap(json["recaps"] as? [[String: Any]])
        XCTAssertEqual(list.map { $0["text"] as? String }, ["Ziel ist X.", "Ziel war Y."])
        XCTAssertEqual(list[0]["at"] as? String, ChatsOutput.iso(now.addingTimeInterval(-120)))
        XCTAssertTrue(list[1]["at"] is NSNull)
    }

    func testEmptyResultExplainsWhyPerProvider() {
        XCTAssertTrue((ChatsRecapOutput.json(entry: entry(.claude), recaps: [], now: now)["note"] as? String)?
            .contains("/config") ?? false)
        XCTAssertEqual(ChatsRecapOutput.json(entry: entry(.codex), recaps: [], now: now)["note"] as? String,
                       "Codex-Chats schreiben keinen Rückblick.")
    }

    func testTextLinesShowAgeAndText() {
        let lines = ChatsRecapOutput.lines(
            entry: entry(.claude), recaps: [ClaudeRecap(at: now.addingTimeInterval(-600), text: "Ziel ist X.")], now: now)
        XCTAssertEqual(lines, ["Rückblicke · c0ffee00 · Intro-Qualität", "  vor 10 min: Ziel ist X."])
    }
}
