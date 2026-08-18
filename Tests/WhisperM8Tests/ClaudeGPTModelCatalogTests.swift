import XCTest
@testable import WhisperM8

final class ClaudeGPTModelCatalogTests: XCTestCase {
    private func models(
        defaultModel: String = "",
        pickerModel: String = "",
        subagentModel: String = "",
        sessionModel: String = "",
        contextWindow: Int = 272_000
    ) throws -> [String] {
        let fragment = ClaudeGPTModelCatalog.availableModelsFragment(
            defaultModel: defaultModel,
            pickerModel: pickerModel,
            subagentModel: subagentModel,
            sessionModel: sessionModel,
            contextWindow: contextWindow
        )
        return try XCTUnwrap(fragment["availableModels"] as? [String])
    }

    func testClaudeAliasesAreCompleteAndFirstInDocumentedOrder() throws {
        XCTAssertEqual(ClaudeGPTModelCatalog.claudeAliases, [
            "default", "best", "fable[1m]", "opus", "sonnet", "haiku",
            "opus[1m]", "sonnet[1m]", "opusplan",
        ])

        let catalog = try models()
        XCTAssertEqual(
            Array(catalog.prefix(ClaudeGPTModelCatalog.claudeAliases.count)),
            ClaudeGPTModelCatalog.claudeAliases
        )
        XCTAssertEqual(
            Array(catalog.dropFirst(ClaudeGPTModelCatalog.claudeAliases.count)),
            Array(catalog.dropFirst(ClaudeGPTModelCatalog.claudeAliases.count)).sorted()
        )
    }

    func testCatalogContainsPlainAndFastPairsForEveryVerifiedGPTModel() throws {
        let catalog = Set(try models())
        let bases = [
            "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
            "gpt-5.5", "gpt-5.4", "gpt-5.4-mini",
        ]

        for base in bases {
            XCTAssertTrue(catalog.contains(base), "Plain-Modell fehlt: \(base)")
            if base == "gpt-5.4-mini" {
                XCTAssertFalse(catalog.contains("\(base)-fast"), "Mini hat keinen Fast-Tier")
            } else {
                XCTAssertTrue(catalog.contains("\(base)-fast"), "Fast-Modell fehlt: \(base)")
            }
        }
    }

    func testCatalogCanonicalizesSupportedConfiguredSources() throws {
        let catalog = Set(try models(
            defaultModel: "  GPT-5.5[1M]  ",
            pickerModel: "GPT-5.4-MINI-FAST[1m]",
            subagentModel: "gpt-5.6-terra-fast",
            sessionModel: "gpt-5.4"
        ))

        XCTAssertTrue(catalog.contains("gpt-5.5"))
        XCTAssertTrue(catalog.contains("gpt-5.5-fast"))
        XCTAssertTrue(catalog.contains("gpt-5.4-mini"))
        XCTAssertFalse(catalog.contains("gpt-5.4-mini-fast"))
        XCTAssertFalse(catalog.contains { $0.lowercased().hasPrefix("gpt-") && $0.lowercased().contains("[1m]") })
    }

    func testCatalogRejectsOlderUnknownAndHistoricalIncompatibleGPTIDs() throws {
        let catalog = Set(try models(
            defaultModel: "gpt-5.3-codex-spark",
            pickerModel: "gpt-5.6-orbit-fast",
            subagentModel: "gpt-4.1",
            sessionModel: "gpt-5.5-historical-fast"
        ))

        XCTAssertFalse(catalog.contains("gpt-5.3-codex-spark"))
        XCTAssertFalse(catalog.contains("gpt-5.6-orbit-fast"))
        XCTAssertFalse(catalog.contains("gpt-4.1"))
        XCTAssertFalse(catalog.contains("gpt-5.5-historical-fast"))
    }

    func testCatalogOmitsAllGPTAboveLargestVerifiedProfile() throws {
        let catalog = try models(contextWindow: 1_000_000)

        XCTAssertEqual(catalog, ClaudeGPTModelCatalog.claudeAliases)
    }

    func testExtended900KCatalogOmitsStandardOnlyModels() throws {
        let catalog = Set(try models(
            defaultModel: "gpt-5.6-terra",
            pickerModel: "gpt-5.6-luna-fast",
            subagentModel: "gpt-5.6-terra-fast",
            sessionModel: "gpt-5.5",
            contextWindow: 900_000
        ))

        // Sol/Terra/Luna und GPT-5.4 tragen den 900k-Vertrag (Messung
        // 2026-08-18); gpt-5.5 und gpt-5.4-mini bleiben beim 272k-Profil
        // und fallen aus dem Picker.
        XCTAssertTrue(catalog.contains("gpt-5.6-sol"))
        XCTAssertTrue(catalog.contains("gpt-5.6-sol-fast"))
        XCTAssertTrue(catalog.contains("gpt-5.6-terra"))
        XCTAssertTrue(catalog.contains("gpt-5.6-luna"))
        XCTAssertTrue(catalog.contains("gpt-5.4"))
        XCTAssertFalse(catalog.contains("gpt-5.5"))
        XCTAssertFalse(catalog.contains("gpt-5.4-mini"))
    }

    func testCatalogDeduplicatesConfiguredModels() throws {
        let catalog = try models(
            defaultModel: "gpt-5.5",
            pickerModel: "gpt-5.5-fast",
            subagentModel: "GPT-5.5[1M]"
        )

        XCTAssertEqual(catalog.filter { $0 == "gpt-5.5" }.count, 1)
        XCTAssertEqual(catalog.filter { $0 == "gpt-5.5-fast" }.count, 1)
    }
}
