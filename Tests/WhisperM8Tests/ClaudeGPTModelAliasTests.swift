import XCTest
@testable import WhisperM8

final class ClaudeGPTModelAliasTests: XCTestCase {
    func testFastEnabledAddsAliasToPlainGPTModel() {
        XCTAssertEqual(
            ClaudeGPTModelAlias.effectiveModel("gpt-5.6-sol", fastEnabled: true),
            "gpt-5.6-sol-fast"
        )
    }

    func testFastEnabledKeepsExplicitFastAliasIdempotent() {
        XCTAssertEqual(
            ClaudeGPTModelAlias.effectiveModel("gpt-5.6-sol-fast", fastEnabled: true),
            "gpt-5.6-sol-fast"
        )
    }

    func testFastDisabledKeepsPlainGPTModel() {
        XCTAssertEqual(
            ClaudeGPTModelAlias.effectiveModel("gpt-5.6-sol", fastEnabled: false),
            "gpt-5.6-sol"
        )
    }

    func testFastDisabledNeverRemovesExplicitFastAlias() {
        XCTAssertEqual(
            ClaudeGPTModelAlias.effectiveModel("gpt-5.6-sol-fast", fastEnabled: false),
            "gpt-5.6-sol-fast"
        )
    }

    func testNonGPTModelStaysUnchanged() {
        XCTAssertEqual(
            ClaudeGPTModelAlias.effectiveModel(" claude-opus-4-8 ", fastEnabled: true),
            "claude-opus-4-8"
        )
    }

    func testEmptyModelStaysEmpty() {
        XCTAssertEqual(ClaudeGPTModelAlias.effectiveModel("  \n", fastEnabled: true), "")
    }

    func testFastAliasStripsMemorySuffix() {
        XCTAssertEqual(
            ClaudeGPTModelAlias.effectiveModel("gpt-5.6-sol[1m]", fastEnabled: true),
            "gpt-5.6-sol-fast"
        )
    }

    func testExplicitFastAliasStripsMemorySuffixIdempotently() {
        XCTAssertEqual(
            ClaudeGPTModelAlias.effectiveModel("gpt-5.6-sol-fast[1m]", fastEnabled: true),
            "gpt-5.6-sol-fast"
        )
    }

    func testMemorySuffixMatchingIsCaseInsensitive() {
        XCTAssertEqual(
            ClaudeGPTModelAlias.effectiveModel("gpt-5.6-sol[1M]", fastEnabled: true),
            "gpt-5.6-sol-fast"
        )
    }

    func testFastDisabledAlsoStripsGPTMemorySuffix() {
        XCTAssertEqual(
            ClaudeGPTModelAlias.effectiveModel("gpt-5.6-terra[1M]", fastEnabled: false),
            "gpt-5.6-terra"
        )
    }

    func testNonGPTMemorySuffixStaysUnchanged() {
        XCTAssertEqual(
            ClaudeGPTModelAlias.effectiveModel("claude-opus-4-8[1m]", fastEnabled: true),
            "claude-opus-4-8[1m]"
        )
    }

    func testUppercaseWhitespaceFastAndMemorySuffixCanonicalizeFully() {
        XCTAssertEqual(
            ClaudeGPTModelAlias.effectiveModel("  GPT-5.6-TERRA-FAST[1M]  ", fastEnabled: true),
            "gpt-5.6-terra-fast"
        )
    }

    func testSupportedCatalogAppliesPerModelContextProfiles() {
        XCTAssertEqual(
            ClaudeGPTModelAlias.supportedEffectiveModel(
                "GPT-5.5[1M]",
                fastEnabled: true,
                contextWindow: 250_000
            ),
            "gpt-5.5-fast"
        )
        XCTAssertNil(
            ClaudeGPTModelAlias.supportedEffectiveModel(
                "gpt-5.3-codex-spark",
                fastEnabled: false
            )
        )
        XCTAssertNil(
            ClaudeGPTModelAlias.supportedEffectiveModel(
                "gpt-5.6-orbit",
                fastEnabled: false
            )
        )
        XCTAssertEqual(
            ClaudeGPTModelAlias.supportedEffectiveModel(
                "gpt-5.6-sol",
                fastEnabled: false,
                contextWindow: 372_000
            ),
            "gpt-5.6-sol"
        )
        XCTAssertNil(
            ClaudeGPTModelAlias.supportedEffectiveModel(
                "gpt-5.6-terra",
                fastEnabled: false,
                contextWindow: 372_000
            )
        )
        XCTAssertNil(
            ClaudeGPTModelAlias.supportedEffectiveModel(
                "gpt-5.6-sol",
                fastEnabled: false,
                contextWindow: 372_001
            )
        )
    }

    func testMiniNeverReceivesUnsupportedFastAlias() {
        XCTAssertEqual(
            ClaudeGPTModelAlias.effectiveModel("gpt-5.4-mini", fastEnabled: true),
            "gpt-5.4-mini"
        )
        XCTAssertEqual(
            ClaudeGPTModelAlias.effectiveModel("GPT-5.4-MINI-FAST[1M]", fastEnabled: true),
            "gpt-5.4-mini"
        )
        XCTAssertFalse(
            ClaudeGPTModelAlias.isSupportedCanonicalModel("gpt-5.4-mini-fast")
        )
    }

    func testSubagentPolicyAllowsOnlySolAndTerra() {
        XCTAssertEqual(
            ClaudeGPTModelAlias.supportedSubagentModel(
                "GPT-5.6-TERRA[1M]",
                fastEnabled: true
            ),
            "gpt-5.6-terra-fast"
        )
        XCTAssertNil(
            ClaudeGPTModelAlias.supportedSubagentModel(
                "gpt-5.6-luna",
                fastEnabled: false
            )
        )
        XCTAssertNil(
            ClaudeGPTModelAlias.supportedSubagentModel(
                "gpt-5.5",
                fastEnabled: false
            )
        )
        XCTAssertNil(
            ClaudeGPTModelAlias.supportedSubagentModel(
                "gpt-5.4-mini",
                fastEnabled: true
            )
        )
    }

    func testContextProfilesExposeExpectedCompactBudgets() {
        XCTAssertEqual(ClaudeGPTContextProfile.standard.rawValue, 272_000)
        XCTAssertEqual(ClaudeGPTContextProfile.standard.expectedAutoCompactTokens, 238_000)
        XCTAssertEqual(ClaudeGPTContextProfile.experimentalSol372K.rawValue, 372_000)
        XCTAssertEqual(
            ClaudeGPTContextProfile.experimentalSol372K.expectedAutoCompactTokens,
            339_000
        )
        XCTAssertEqual(
            ClaudeGPTContextProfile.matching(contextWindow: 372_000),
            .experimentalSol372K
        )
        XCTAssertNil(ClaudeGPTContextProfile.matching(contextWindow: 250_000))
    }
}
