import XCTest
@testable import WhisperM8

final class ClaudeGPTModelCatalogTests: XCTestCase {
    private func models(
        defaultModel: String = "",
        subagentModel: String = ""
    ) throws -> [String] {
        let fragment = ClaudeGPTModelCatalog.availableModelsFragment(
            defaultModel: defaultModel,
            subagentModel: subagentModel
        )
        return try XCTUnwrap(fragment["availableModels"] as? [String])
    }

    func testClaudeAliasesAreCompleteAndFirstInDocumentedOrder() throws {
        XCTAssertEqual(ClaudeGPTModelCatalog.claudeAliases, [
            "default", "best", "fable", "opus", "sonnet", "haiku",
            "opus[1m]", "sonnet[1m]", "opusplan",
        ])

        let catalog = try models(defaultModel: "gpt-5.6-orbit", subagentModel: "gpt-5.6-nebula")
        XCTAssertEqual(
            Array(catalog.prefix(ClaudeGPTModelCatalog.claudeAliases.count)),
            ClaudeGPTModelCatalog.claudeAliases
        )
        XCTAssertEqual(
            Array(catalog.dropFirst(ClaudeGPTModelCatalog.claudeAliases.count)),
            Array(catalog.dropFirst(ClaudeGPTModelCatalog.claudeAliases.count)).sorted()
        )
    }

    func testCatalogContainsPlainAndFastPairsForAllGPTSources() throws {
        let catalog = Set(try models(
            defaultModel: "  gpt-5.6-orbit  ",
            subagentModel: "\n gpt-5.6-nebula \t"
        ))
        let bases = [
            AppPreferences.claudeGPTCanonicalModel,
            "gpt-5.6-orbit",
            "gpt-5.6-nebula",
            "gpt-5.6-luna",
            "gpt-5.6-terra",
        ]

        for base in bases {
            XCTAssertTrue(catalog.contains(base), "Plain-Modell fehlt: \(base)")
            XCTAssertTrue(catalog.contains("\(base)-fast"), "Fast-Modell fehlt: \(base)")
        }
    }

    func testCatalogDeduplicatesCanonicalAndIgnoresEmptyInputs() throws {
        let catalog = try models(
            defaultModel: " \(AppPreferences.claudeGPTCanonicalModel) ",
            subagentModel: "  \n "
        )

        XCTAssertEqual(catalog.filter { $0 == AppPreferences.claudeGPTCanonicalModel }.count, 1)
        XCTAssertEqual(catalog.filter { $0 == "\(AppPreferences.claudeGPTCanonicalModel)-fast" }.count, 1)
        XCTAssertFalse(catalog.contains(""))
        XCTAssertTrue(catalog.contains("gpt-5.6-luna"))
        XCTAssertTrue(catalog.contains("gpt-5.6-terra-fast"))
    }

    func testCatalogPreservesMemorySuffixForPlainAndFastVariants() throws {
        let catalog = Set(try models(defaultModel: "gpt-5.6-orbit[1m]"))

        XCTAssertTrue(catalog.contains("gpt-5.6-orbit[1m]"))
        XCTAssertTrue(catalog.contains("gpt-5.6-orbit-fast[1m]"))
    }

    func testExplicitFastInputAlsoAddsPlainPendantWithoutDoubleSuffix() throws {
        let catalog = Set(try models(defaultModel: "gpt-5.6-orbit-fast"))

        XCTAssertTrue(catalog.contains("gpt-5.6-orbit"))
        XCTAssertTrue(catalog.contains("gpt-5.6-orbit-fast"))
        XCTAssertFalse(catalog.contains("gpt-5.6-orbit-fast-fast"))
    }
}
