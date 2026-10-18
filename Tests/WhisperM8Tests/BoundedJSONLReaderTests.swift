import Foundation
import XCTest
@testable import WhisperM8

final class BoundedJSONLReaderTests: XCTestCase {
    private func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8BoundedJSONL-\(UUID().uuidString).jsonl")
        try data.write(to: url)
        return url
    }

    /// LR-AK-008: Schnittkante mitten in einem Mehrbyte-Zeichen verwarf den ganzen Prefix.
    func testLinesSurviveCutInsideMultibyteCharacter() throws {
        var data = Data("{\"a\":1}\n".utf8) // 8 Bytes
        data.append(Data(String(repeating: "ä", count: 20).utf8))
        let url = try temporaryFile(data)
        defer { try? FileManager.default.removeItem(at: url) }

        // 8 + 3 Bytes: das zweite „ä“ ist zerschnitten.
        let result = BoundedJSONLReader.lines(from: url, maxLines: 10, maxBytes: 11)

        XCTAssertEqual(result?.lines, ["{\"a\":1}"])
        XCTAssertEqual(result?.bytesRead, 11)
    }

    func testLinesKeepCompleteFileUnchanged() throws {
        let url = try temporaryFile(Data("eins\nzwei ä\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let result = BoundedJSONLReader.lines(from: url, maxLines: 10, maxBytes: 1024)
        XCTAssertEqual(result?.lines, ["eins", "zwei ä"])
    }

    func testClaudeIndexerImportsSessionWhenLimitCutsUmlaut() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8ClaudeUTF8Edge-\(UUID().uuidString)", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("-Users-test-repo", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)

        let head = [
            #"{"type":"ai-title","aiTitle":"Umlaut Rand","sessionId":"11111111-1111-4111-8111-111111111111"}"#,
            #"{"type":"user","timestamp":"2026-05-09T12:00:00.000Z","sessionId":"11111111-1111-4111-8111-111111111111","cwd":"/Users/test/repo","message":{"role":"user","content":"Fix this"}}"#,
            ""
        ].joined(separator: "\n")
        var data = Data(head.utf8)
        let limit = 1 * 1024 * 1024
        // Ein Leerzeichen verschiebt bei Bedarf die „ä“-Paare so, dass Byte 1.048.576
        // zwischen die zwei Bytes eines Zeichens fällt (Grenzabstand ungerade).
        if (limit - data.count) % 2 == 0 { data.append(0x20) }
        let distanceToLimit = limit - data.count
        XCTAssertEqual(distanceToLimit % 2, 1, "Testaufbau: Grenze muss mitten im Zeichen liegen")
        data.append(Data(String(repeating: "ä", count: distanceToLimit / 2 + 10).utf8))
        try data.write(to: projectDirectory.appendingPathComponent("11111111-1111-4111-8111-111111111111.jsonl"))

        let sessions = ClaudeSessionIndexer(projectsDirectory: root).indexedSessions()

        XCTAssertEqual(sessions.first?.externalSessionID, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(sessions.first?.title, "Umlaut Rand")
    }
}
