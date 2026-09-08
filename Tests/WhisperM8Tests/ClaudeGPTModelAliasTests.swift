import XCTest
@testable import WhisperM8

final class ClaudeGPTModelAliasTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        useFallbackGPTCatalogForTests()
    }

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
                contextWindow: 900_000
            ),
            "gpt-5.6-sol"
        )
        // Terra/Luna und GPT-5.4 tragen den 900k-Vertrag (Messung 2026-08-18);
        // gpt-5.5 und gpt-5.4-mini bleiben beim 272k-Profil.
        XCTAssertEqual(
            ClaudeGPTModelAlias.supportedEffectiveModel(
                "gpt-5.6-terra",
                fastEnabled: false,
                contextWindow: 900_000
            ),
            "gpt-5.6-terra"
        )
        XCTAssertEqual(
            ClaudeGPTModelAlias.supportedEffectiveModel(
                "gpt-5.4",
                fastEnabled: false,
                contextWindow: 900_000
            ),
            "gpt-5.4"
        )
        XCTAssertNil(
            ClaudeGPTModelAlias.supportedEffectiveModel(
                "gpt-5.5",
                fastEnabled: false,
                contextWindow: 900_000
            )
        )
        XCTAssertNil(
            ClaudeGPTModelAlias.supportedEffectiveModel(
                "gpt-5.4-mini",
                fastEnabled: false,
                contextWindow: 900_000
            )
        )
        XCTAssertNil(
            ClaudeGPTModelAlias.supportedEffectiveModel(
                "gpt-5.6-sol",
                fastEnabled: false,
                contextWindow: 900_001
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

    func testAstraIsMainAndSubagentCapableAcrossBothProfiles() {
        // Codex-Katalog 2026-09-04: Fast-Tier vorhanden; 900k per Direktmessung
        // 2026-09-06 (905.911 Input-Tokens angenommen) verifiziert.
        XCTAssertEqual(
            ClaudeGPTModelAlias.effectiveModel("GPT-6-ASTRA[1M]", fastEnabled: true),
            "gpt-6-astra-fast"
        )
        XCTAssertEqual(
            ClaudeGPTModelAlias.supportedEffectiveModel("gpt-6-astra", fastEnabled: false),
            "gpt-6-astra"
        )
        XCTAssertEqual(
            ClaudeGPTModelAlias.supportedSubagentModel("gpt-6-astra", fastEnabled: true),
            "gpt-6-astra-fast"
        )
        XCTAssertEqual(
            ClaudeGPTModelAlias.maximumContextWindow(for: "gpt-6-astra-fast"),
            ClaudeGPTContextProfile.extended900K.rawValue
        )
        XCTAssertEqual(
            ClaudeGPTModelAlias.supportedEffectiveModel(
                "gpt-6-astra",
                fastEnabled: false,
                contextWindow: 900_000
            ),
            "gpt-6-astra"
        )
        XCTAssertEqual(
            ClaudeGPTModelAlias.supportedSubagentModel(
                "gpt-6-astra",
                fastEnabled: false,
                contextWindow: 900_000
            ),
            "gpt-6-astra"
        )
        XCTAssertNil(
            ClaudeGPTModelAlias.supportedEffectiveModel(
                "gpt-6-astra",
                fastEnabled: false,
                contextWindow: 900_001
            )
        )
    }

    func testSubagentPolicyAllowsEveryCatalogModel() {
        XCTAssertEqual(
            ClaudeGPTModelAlias.supportedSubagentModel(
                "GPT-5.6-TERRA[1M]",
                fastEnabled: true
            ),
            "gpt-5.6-terra-fast"
        )
        XCTAssertEqual(
            ClaudeGPTModelAlias.supportedSubagentModel("gpt-5.6-luna", fastEnabled: false),
            "gpt-5.6-luna"
        )
        XCTAssertEqual(
            ClaudeGPTModelAlias.supportedSubagentModel("gpt-5.5", fastEnabled: false),
            "gpt-5.5"
        )
        // Mini hat laut Katalog keinen Fast-Tier — bleibt auch hier suffixlos.
        XCTAssertEqual(
            ClaudeGPTModelAlias.supportedSubagentModel("gpt-5.4-mini", fastEnabled: true),
            "gpt-5.4-mini"
        )
        XCTAssertNil(
            ClaudeGPTModelAlias.supportedSubagentModel("gpt-5.6-orbit", fastEnabled: true)
        )
    }

    func testAutoSentinelResolvesToCatalogFrontier() {
        XCTAssertEqual(ClaudeGPTModelAlias.frontierModel(), "gpt-6-astra")
        XCTAssertEqual(ClaudeGPTModelAlias.canonicalGPTModel("auto"), "gpt-6-astra")
        XCTAssertEqual(ClaudeGPTModelAlias.canonicalGPTModel(" GPT-AUTO[1M] "), "gpt-6-astra")
        XCTAssertEqual(ClaudeGPTModelAlias.canonicalGPTModel("auto-fast"), "gpt-6-astra-fast")
        XCTAssertEqual(
            ClaudeGPTModelAlias.supportedEffectiveModel("auto", fastEnabled: true, contextWindow: 900_000),
            "gpt-6-astra-fast"
        )
        XCTAssertEqual(
            ClaudeGPTModelAlias.fallbackEffectiveModel(fastEnabled: false, contextWindow: 900_000),
            "gpt-6-astra"
        )
        XCTAssertNil(ClaudeGPTModelAlias.canonicalGPTModel("automatic"))
    }

    func testSmallModelFollowsCatalogOrderProfileAndUpgradeChain() {
        // Fallback-Katalog: Mini ist das letzte Backend-Modell → 272k-Profil.
        XCTAssertEqual(ClaudeGPTModelAlias.smallModel(contextWindow: 272_000), "gpt-5.4-mini")
        // 900k: Mini trägt das Profil nicht → Nachfolger laut Katalog (Luna).
        let retiredMini = CodexCatalogModel(
            slug: "gpt-5.4-mini", displayName: "Mini", detail: nil, defaultEffort: "medium",
            efforts: CodexModelCatalog.baselineEfforts, priority: 23, supportsFastTier: false,
            upgradeModel: "gpt-5.6-luna", retirementDate: Date(timeIntervalSince1970: 0)
        )
        var models = CodexModelCatalog.fallback.models.filter { $0.slug != "gpt-5.4-mini" }
        models.append(retiredMini)
        let catalog = CodexModelCatalog(models: models, fetchedAt: nil)
        // Fallback-Katalog (ohne Abkündigung): Mini/5.5 tragen 900k nicht, das
        // nächste kleinere Modell mit 1M-Klasse ist GPT-5.4.
        XCTAssertEqual(ClaudeGPTModelAlias.smallModel(contextWindow: 900_000, catalog: .fallback), "gpt-5.4")
        // Live-Situation (Cache 2026-09-04: kein gpt-5.4 mehr, Mini abgekündigt → Luna).
        let live = CodexModelCatalog(models: models.filter { $0.slug != "gpt-5.4" }, fetchedAt: nil)
        XCTAssertEqual(ClaudeGPTModelAlias.smallModel(contextWindow: 900_000, catalog: live), "gpt-5.6-luna")
        // Abgekündigt: auch im 272k-Profil nicht mehr wählbar → Nachfolger.
        XCTAssertEqual(ClaudeGPTModelAlias.smallModel(contextWindow: 272_000, catalog: catalog), "gpt-5.6-luna")
        XCTAssertNil(ClaudeGPTModelAlias.supportedEffectiveModel("gpt-5.4-mini", fastEnabled: false, catalog: catalog))
        XCTAssertFalse(ClaudeGPTModelAlias.backendModelSlugs(catalog: catalog).contains("gpt-5.4-mini"))
        // Nur ein Modell im Katalog → Frontier, nie ein abgelehntes Modell.
        let single = CodexModelCatalog(models: [CodexCatalogModel(
            slug: "gpt-7-nova", displayName: "Nova", detail: nil, defaultEffort: "medium",
            efforts: CodexModelCatalog.baselineEfforts, priority: 0, maxContextWindow: 872_000
        )], fetchedAt: nil)
        XCTAssertEqual(ClaudeGPTModelAlias.smallModel(contextWindow: 900_000, catalog: single), "gpt-7-nova")
    }

    func testCapabilitiesComeFromCatalogMetadata() {
        // Fiktiver Katalog: ein neues Modell ohne Codeänderung, eines ohne
        // Fast-Tier, eines ohne API-Freigabe, eines mit 128k.
        let catalog = CodexModelCatalog(
            models: [
                CodexCatalogModel(slug: "gpt-7-nova", displayName: "GPT-7-Nova", detail: nil,
                                  defaultEffort: "medium", efforts: CodexModelCatalog.baselineEfforts,
                                  priority: 0, maxContextWindow: 872_000),
                CodexCatalogModel(slug: "gpt-7-nova-mini", displayName: "Mini", detail: nil,
                                  defaultEffort: "medium", efforts: CodexModelCatalog.baselineEfforts,
                                  priority: 1, supportsFastTier: false),
                CodexCatalogModel(slug: "gpt-7-internal", displayName: "Internal", detail: nil,
                                  defaultEffort: "medium", efforts: CodexModelCatalog.baselineEfforts,
                                  priority: 2, supportedInAPI: false),
                CodexCatalogModel(slug: "gpt-6.9-spark", displayName: "Spark", detail: nil,
                                  defaultEffort: "medium", efforts: CodexModelCatalog.baselineEfforts,
                                  priority: 3, contextWindow: 128_000),
            ],
            fetchedAt: nil
        )
        XCTAssertEqual(ClaudeGPTModelAlias.frontierModel(catalog: catalog), "gpt-7-nova")
        XCTAssertEqual(ClaudeGPTModelAlias.backendModelSlugs(catalog: catalog), ["gpt-7-nova", "gpt-7-nova-mini"])
        XCTAssertEqual(
            ClaudeGPTModelAlias.supportedEffectiveModel("gpt-7-nova", fastEnabled: true, contextWindow: 900_000, catalog: catalog),
            "gpt-7-nova-fast"
        )
        XCTAssertEqual(
            ClaudeGPTModelAlias.supportedEffectiveModel("gpt-7-nova-mini", fastEnabled: true, catalog: catalog),
            "gpt-7-nova-mini"
        )
        XCTAssertNil(
            ClaudeGPTModelAlias.supportedEffectiveModel("gpt-7-nova-mini", fastEnabled: false, contextWindow: 900_000, catalog: catalog)
        )
        XCTAssertNil(ClaudeGPTModelAlias.supportedEffectiveModel("gpt-7-internal", fastEnabled: false, catalog: catalog))
        XCTAssertNil(ClaudeGPTModelAlias.supportedEffectiveModel("gpt-6.9-spark", fastEnabled: false, catalog: catalog))
        XCTAssertEqual(
            ClaudeGPTModelAlias.suggestions(includeFastVariants: true, catalog: catalog),
            ["auto", "gpt-7-nova", "gpt-7-nova-fast", "gpt-7-nova-mini"]
        )
        XCTAssertEqual(
            ClaudeGPTModelAlias.supportedModelsSummary(contextWindow: 900_000, catalog: catalog),
            "gpt-7-nova"
        )
    }

    func testContextProfilesExposeExpectedCompactBudgets() {
        XCTAssertEqual(ClaudeGPTContextProfile.standard.rawValue, 272_000)
        XCTAssertEqual(ClaudeGPTContextProfile.standard.expectedAutoCompactTokens, 238_000)
        XCTAssertEqual(ClaudeGPTContextProfile.extended900K.rawValue, 900_000)
        XCTAssertEqual(
            ClaudeGPTContextProfile.extended900K.expectedAutoCompactTokens,
            830_000
        )
        XCTAssertEqual(
            ClaudeGPTContextProfile.matching(contextWindow: 900_000),
            .extended900K
        )
        XCTAssertNil(ClaudeGPTContextProfile.matching(contextWindow: 372_000))
        XCTAssertNil(ClaudeGPTContextProfile.matching(contextWindow: 250_000))
    }
}
