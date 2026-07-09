import Foundation
import XCTest
@testable import WhisperM8

/// Parser + Stat-Cache des ~/.codex/config.toml-Readers (nur die zwei
/// Top-Level-Keys `model` / `model_reasoning_effort`).
final class CodexGlobalConfigReaderTests: XCTestCase {
    func testParsesQuotedTopLevelKeys() {
        let defaults = CodexGlobalConfigReader.parse("""
        # Kommentar
        model = "gpt-5.6-sol"
        model_reasoning_effort = "high"
        approval_policy = "never"
        """)
        XCTAssertEqual(defaults.model, "gpt-5.6-sol")
        XCTAssertEqual(defaults.effort, "high")
    }

    func testParsesBareValuesAndInlineComments() {
        let defaults = CodexGlobalConfigReader.parse("""
        model = gpt-5.4 # bare TOML-Werte toleriert der Reader ebenfalls
        model_reasoning_effort = xhigh
        """)
        XCTAssertEqual(defaults.model, "gpt-5.4")
        XCTAssertEqual(defaults.effort, "xhigh")
    }

    /// Ein `model` in einer [section] (z.B. Profile) ist NICHT der globale
    /// Default — der Top-Level-Bereich endet an der ersten Sektion.
    func testStopsAtFirstSection() {
        let defaults = CodexGlobalConfigReader.parse("""
        model_reasoning_effort = "medium"

        [profiles.turbo]
        model = "gpt-5.6-luna"
        """)
        XCTAssertNil(defaults.model)
        XCTAssertEqual(defaults.effort, "medium")
    }

    func testEmptyOrIrrelevantContentYieldsEmptyDefaults() {
        XCTAssertEqual(CodexGlobalConfigReader.parse(""), .empty)
        XCTAssertEqual(CodexGlobalConfigReader.parse("sandbox_mode = \"read-only\""), .empty)
        // Leerer Wert zählt nicht als gesetzt.
        XCTAssertEqual(CodexGlobalConfigReader.parse("model = \"\""), .empty)
    }

    func testReaderCachesByStatAndFallsBackWhenMissing() {
        let url = URL(fileURLWithPath: "/fake/config.toml")
        var loadCount = 0
        var stat: (mtime: Date, size: Int)? = (Date(timeIntervalSince1970: 100), 10)
        var content = "model = \"gpt-5.6-sol\"\n"

        let reader = CodexGlobalConfigReader(
            fileURL: url,
            dataLoader: { _ in loadCount += 1; return Data(content.utf8) },
            statLoader: { _ in stat }
        )

        XCTAssertEqual(reader.defaults().model, "gpt-5.6-sol")
        _ = reader.defaults()
        XCTAssertEqual(loadCount, 1, "unveränderte (mtime,size) darf nicht neu lesen")

        content = "model = \"gpt-5.7-nova\"\n"
        stat = (Date(timeIntervalSince1970: 200), 12)
        XCTAssertEqual(reader.defaults().model, "gpt-5.7-nova")
        XCTAssertEqual(loadCount, 2)

        // Datei verschwindet → letzter guter Stand bleibt.
        stat = nil
        XCTAssertEqual(reader.defaults().model, "gpt-5.7-nova")
    }
}
