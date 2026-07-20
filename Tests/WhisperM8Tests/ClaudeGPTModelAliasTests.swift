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

    func testFastAliasIsInsertedBeforeMemorySuffix() {
        XCTAssertEqual(
            ClaudeGPTModelAlias.effectiveModel("gpt-5.6-sol[1m]", fastEnabled: true),
            "gpt-5.6-sol-fast[1m]"
        )
    }

    func testExplicitFastAliasBeforeMemorySuffixIsIdempotent() {
        XCTAssertEqual(
            ClaudeGPTModelAlias.effectiveModel("gpt-5.6-sol-fast[1m]", fastEnabled: true),
            "gpt-5.6-sol-fast[1m]"
        )
    }

    func testMemorySuffixMatchingIsCaseInsensitiveAndPreservesSpelling() {
        XCTAssertEqual(
            ClaudeGPTModelAlias.effectiveModel("gpt-5.6-sol[1M]", fastEnabled: true),
            "gpt-5.6-sol-fast[1M]"
        )
    }

    func testMiniModelUsesTheSameAliasRule() {
        XCTAssertEqual(
            ClaudeGPTModelAlias.effectiveModel("gpt-5.4-mini", fastEnabled: true),
            "gpt-5.4-mini-fast"
        )
    }
}
