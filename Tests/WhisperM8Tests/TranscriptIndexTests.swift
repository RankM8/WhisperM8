import Foundation
import XCTest
@testable import WhisperM8

final class TranscriptIndexTests: XCTestCase {
    /// P3 S1: `transcriptURL` muss denselben Verzeichnisnamen liefern wie
    /// Claudes echtes Encoding (jeder Nicht-Alphanumerik-Char → `-`) — vorher
    /// wurde nur `/` ersetzt, Pfade mit `.`/`_`/Leerzeichen liefen ins Leere.
    func testTranscriptURLMatchesLocatorEncoding() {
        let trickyPaths = [
            "/Users/foo/repos/my_project",
            "/Users/foo/repos/my.project",
            "/Users/foo/repos/Projekt Name",
            "/Users/foo/repos/normal",
        ]
        for path in trickyPaths {
            let url = ClaudeTranscriptReader.transcriptURL(forCwd: path, sessionID: "abc")
            let expectedDir = AgentTranscriptLocator.encodeClaudeCwd(path)
            XCTAssertEqual(
                url.deletingLastPathComponent().lastPathComponent,
                expectedDir,
                "Encoding-Divergenz für \(path)"
            )
        }
    }

    /// P3 S6: Tail-Reader liefert vollständige Zeilen vom Dateiende und
    /// verwirft die erste angeschnittene Zeile.
    func testTailLinesDropPartialFirstLine() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptIndexTests-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let lines = (0..<100).map { "{\"n\": \($0), \"pad\": \"\(String(repeating: "x", count: 50))\"}" }
        try lines.joined(separator: "\n").appending("\n").data(using: .utf8)!.write(to: url)

        let tail = TranscriptTailReader.tailLines(fileURL: url, tailBytes: 500)
        XCTAssertFalse(tail.isEmpty)
        XCTAssertLessThan(tail.count, 100, "Nur das Dateiende darf gelesen werden")
        // Jede gelieferte Zeile muss vollständig (parsebar) sein.
        for line in tail {
            XCTAssertNotNil(
                try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                "Angeschnittene Zeile wurde nicht verworfen: \(line)"
            )
        }
    }

    func testTailLinesSmallFileReturnsEverything() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptIndexTests-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{\"a\":1}\n{\"a\":2}\n".utf8).write(to: url)

        let tail = TranscriptTailReader.tailLines(fileURL: url, tailBytes: 1024)
        XCTAssertEqual(tail.count, 2, "Datei kleiner als tailBytes → alle Zeilen, nichts verwerfen")
    }
}
