import Foundation
import XCTest
@testable import WhisperM8

/// Deckt Parsing, Merge (Cache ∪ Fallback), Frontier-Ermittlung, Picker-Helper
/// und den Store-Stat-Cache ab. Fixtures als Inline-JSON — bewusst KEINE
/// Bundle-Ressource (Package.swift/Makefile-Gotcha).
final class CodexModelCatalogTests: XCTestCase {
    // MARK: - Fixtures

    /// Minimales, aber strukturtreues Abbild von ~/.codex/models_cache.json.
    private func fixtureJSON(models: String) -> Data {
        Data("""
        {
          "fetched_at": "2026-07-09T20:22:15.287823Z",
          "etag": "W/\\"abc\\"",
          "client_version": "0.144.0",
          "models": [\(models)]
        }
        """.utf8)
    }

    private func modelJSON(
        slug: String,
        displayName: String? = nil,
        priority: Int,
        visibility: String = "list",
        defaultEffort: String = "medium",
        efforts: [String] = ["low", "medium", "high", "xhigh"]
    ) -> String {
        let levels = efforts
            .map { #"{"effort": "\#($0)", "description": "desc \#($0)"}"# }
            .joined(separator: ",")
        return """
        {
          "slug": "\(slug)",
          "display_name": "\(displayName ?? slug.uppercased())",
          "description": "Beschreibung \(slug)",
          "default_reasoning_level": "\(defaultEffort)",
          "supported_reasoning_levels": [\(levels)],
          "visibility": "\(visibility)",
          "priority": \(priority),
          "context_window": 272000,
          "unbekanntes_feld": {"nested": true}
        }
        """
    }

    private func parse(_ models: String) -> CodexModelCatalog? {
        CodexModelCatalogStore.parse(fixtureJSON(models: models))
    }

    // MARK: - Parsing

    func testParsesModelsAndFiltersHiddenOnes() throws {
        let catalog = try XCTUnwrap(parse([
            modelJSON(slug: "gpt-5.5", priority: 0),
            modelJSON(slug: "gpt-5.6-sol", priority: 1,
                      defaultEffort: "low",
                      efforts: ["low", "medium", "high", "xhigh", "max", "ultra"]),
            modelJSON(slug: "codex-auto-review", priority: 43, visibility: "hide"),
        ].joined(separator: ",")))

        XCTAssertNil(catalog.model(slug: "codex-auto-review"), "hide-Modelle gehören nicht in den Picker")
        let sol = try XCTUnwrap(catalog.model(slug: "gpt-5.6-sol"))
        XCTAssertEqual(sol.efforts.map(\.effort), ["low", "medium", "high", "xhigh", "max", "ultra"])
        XCTAssertEqual(sol.defaultEffort, "low")
        XCTAssertEqual(sol.maxEffort, "ultra")
        XCTAssertEqual(sol.efforts.first?.detail, "desc low")
        XCTAssertNotNil(catalog.fetchedAt)
    }

    func testLenientDecodeSkipsBrokenModelObject() throws {
        // Ein Objekt ohne slug (Pflichtfeld) darf die übrigen nicht verwerfen.
        let catalog = try XCTUnwrap(parse([
            modelJSON(slug: "gpt-5.5", priority: 0),
            #"{"display_name": "kaputt", "priority": "keine Zahl"}"#,
            modelJSON(slug: "gpt-5.4", priority: 16),
        ].joined(separator: ",")))
        XCTAssertNotNil(catalog.model(slug: "gpt-5.5"))
        XCTAssertNotNil(catalog.model(slug: "gpt-5.4"))
    }

    func testGarbageDataReturnsNil() {
        XCTAssertNil(CodexModelCatalogStore.parse(Data("kein json".utf8)))
        XCTAssertNil(CodexModelCatalogStore.parse(fixtureJSON(models: "")), "leeres models-Array → Fallback statt leerer Katalog")
    }

    // MARK: - Merge (Cache ∪ Fallback)

    func testStaleCacheIsUnionedWithFallback() throws {
        // 0.142.5-Szenario: Cache kennt die gpt-5.6-Familie noch nicht.
        let catalog = try XCTUnwrap(parse([
            modelJSON(slug: "gpt-5.5", priority: 0),
            modelJSON(slug: "gpt-5.4", priority: 16),
        ].joined(separator: ",")))

        XCTAssertNotNil(catalog.model(slug: "gpt-5.6-sol"), "Fallback muss fehlende Binary-Modelle ergänzen")
        XCTAssertNotNil(catalog.model(slug: "gpt-5.6-luna"))
        // Priority-Sortierung über Merge-Grenzen hinweg: 5.5 (0) vor sol (1) vor 5.4 (16).
        XCTAssertEqual(catalog.models.prefix(4).map(\.slug), ["gpt-5.5", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"])
    }

    func testCacheWinsOverFallbackForSameSlug() throws {
        // Der Cache meldet für sol ein neues Level oberhalb von ultra — er gewinnt.
        let catalog = try XCTUnwrap(parse(
            modelJSON(slug: "gpt-5.6-sol", displayName: "GPT-5.6-Sol (Server)", priority: 1,
                      efforts: ["low", "medium", "high", "xhigh", "max", "ultra", "hyper"])
        ))
        let sol = try XCTUnwrap(catalog.model(slug: "gpt-5.6-sol"))
        XCTAssertEqual(sol.displayName, "GPT-5.6-Sol (Server)")
        XCTAssertEqual(sol.maxEffort, "hyper")
    }

    // MARK: - Frontier

    func testFrontierPrefersHighestSlugVersionNotPriority() throws {
        let catalog = try XCTUnwrap(parse([
            modelJSON(slug: "gpt-5.5", priority: 0),
            modelJSON(slug: "gpt-5.6-sol", priority: 1),
            modelJSON(slug: "gpt-5.6-terra", priority: 2),
        ].joined(separator: ",")))
        XCTAssertEqual(catalog.frontierModel?.slug, "gpt-5.6-sol", "höchste Version, Tie-Break kleinste priority")
    }

    func testFrontierPicksHypotheticalNewerVersionAutomatically() throws {
        let catalog = try XCTUnwrap(parse([
            modelJSON(slug: "gpt-5.6-sol", priority: 1),
            modelJSON(slug: "gpt-5.7-nova", priority: 9),
        ].joined(separator: ",")))
        XCTAssertEqual(catalog.frontierModel?.slug, "gpt-5.7-nova")
    }

    func testFrontierIgnoresUnparsableSlugs() {
        let catalog = CodexModelCatalog(
            models: [
                CodexCatalogModel(slug: "mystery-model", displayName: "?", detail: nil,
                                  defaultEffort: "medium",
                                  efforts: CodexModelCatalog.baselineEfforts, priority: 0),
            ],
            fetchedAt: nil
        )
        // Kein parsebarer Slug → defaultModel (erster gelisteter).
        XCTAssertEqual(catalog.frontierModel?.slug, "mystery-model")
    }

    func testSlugVersionParsing() {
        XCTAssertEqual(CodexModelCatalog.parseSlugVersion("gpt-5.6-sol")?.minor, 6)
        XCTAssertEqual(CodexModelCatalog.parseSlugVersion("gpt-6.0")?.major, 6)
        XCTAssertNil(CodexModelCatalog.parseSlugVersion("codex-auto-review"))
        XCTAssertNil(CodexModelCatalog.parseSlugVersion("o3-pro"))
    }

    // MARK: - Picker-Helper

    func testUnknownPersistedModelStaysSelectable() {
        let catalog = CodexModelCatalog.fallback
        let slugs = catalog.pickerModelSlugs(including: "gpt-9.9-nova")
        XCTAssertEqual(slugs.first, "gpt-9.9-nova", "persistierter Fremdwert darf nie still verschwinden")
        XCTAssertTrue(slugs.contains("gpt-5.6-sol"))
        // Bekannte und leere Werte werden nicht dupliziert/vorangestellt.
        XCTAssertEqual(catalog.pickerModelSlugs(including: "gpt-5.5").first, "gpt-5.5")
        XCTAssertFalse(catalog.pickerModelSlugs(including: "").contains(""))
        // "auto" wird an der UI-Schicht separat vorangestellt — nicht hier.
        XCTAssertFalse(catalog.pickerModelSlugs(including: "auto").contains("auto"))
    }

    func testUnknownPersistedEffortStaysSelectable() {
        let catalog = CodexModelCatalog.fallback
        let efforts = catalog.pickerEffortValues(forModelSlug: "gpt-5.6-sol", including: "hyper")
        XCTAssertEqual(efforts.first, "hyper")
        XCTAssertEqual(Array(efforts.dropFirst()), ["low", "medium", "high", "xhigh", "max", "ultra"])
    }

    func testEffortsForUnknownModelFallBackToBaseline() {
        let efforts = CodexModelCatalog.fallback.efforts(forModelSlug: "gpt-9.9-nova")
        XCTAssertEqual(efforts.map(\.effort), ["low", "medium", "high", "xhigh"])
    }

    // MARK: - Konflikt-Auflösung (Modellwechsel)

    func testShouldReplaceEffortOnlyForKnownButUnsupportedCombos() {
        let catalog = CodexModelCatalog.fallback
        // ultra → luna: bekannt, aber nicht unterstützt → ersetzen (auf "high").
        XCTAssertTrue(catalog.shouldReplaceEffort("ultra", forModelSlug: "gpt-5.6-luna"))
        // xhigh → spark: unterstützt → nicht anfassen.
        XCTAssertFalse(catalog.shouldReplaceEffort("xhigh", forModelSlug: "gpt-5.3-codex-spark"))
        // Gänzlich unbekannter Effort (neuer als Katalog) → durchreichen.
        XCTAssertFalse(catalog.shouldReplaceEffort("hyper", forModelSlug: "gpt-5.6-luna"))
        // Unbekanntes Modell → nichts umschreiben.
        XCTAssertFalse(catalog.shouldReplaceEffort("ultra", forModelSlug: "gpt-9.9-nova"))
        XCTAssertEqual(CodexModelCatalog.conflictFallbackEffort, "high")
    }

    // MARK: - Anzeige

    func testEffortDisplayNames() {
        XCTAssertEqual(CodexModelCatalog.effortDisplayName("xhigh"), "Extra High")
        XCTAssertEqual(CodexModelCatalog.effortDisplayName("max"), "Max")
        XCTAssertEqual(CodexModelCatalog.effortDisplayName("ultra"), "Ultra")
        XCTAssertEqual(CodexModelCatalog.effortDisplayName("minimal"), "Minimal")
        XCTAssertEqual(CodexModelCatalog.effortDisplayName("foo"), "Foo")
    }

    func testModelDisplayNameFallsBackToRawSlug() {
        XCTAssertEqual(CodexModelCatalog.fallback.modelDisplayName("gpt-5.6-sol"), "GPT-5.6-Sol")
        XCTAssertEqual(CodexModelCatalog.fallback.modelDisplayName("gpt-9.9-nova"), "gpt-9.9-nova")
    }

    // MARK: - Auto-Sentinel

    func testResolveSlugAutoPicksFrontier() {
        XCTAssertEqual(
            CodexModelSelection.resolveSlug("auto", catalog: .fallback),
            "gpt-5.6-sol"
        )
        XCTAssertEqual(
            CodexModelSelection.resolveSlug("gpt-5.4", catalog: .fallback),
            "gpt-5.4", "konkrete Slugs sind Pass-through"
        )
        XCTAssertEqual(
            CodexModelSelection.resolveSlug(" auto ", catalog: .fallback),
            "gpt-5.6-sol", "Whitespace tolerieren"
        )
    }

    // MARK: - Store (Stat-Cache)

    func testStoreReparsesOnlyWhenStatChanges() {
        let url = URL(fileURLWithPath: "/fake/models_cache.json")
        var loadCount = 0
        var stat: (mtime: Date, size: Int) = (Date(timeIntervalSince1970: 100), 10)
        let json = fixtureJSON(models: modelJSON(slug: "gpt-5.5", priority: 0))

        let store = CodexModelCatalogStore(
            fileURL: url,
            dataLoader: { _ in loadCount += 1; return json },
            statLoader: { _ in stat }
        )

        _ = store.catalog()
        _ = store.catalog()
        XCTAssertEqual(loadCount, 1, "unveränderte (mtime,size) darf nicht neu parsen")

        stat = (Date(timeIntervalSince1970: 200), 10)
        _ = store.catalog()
        XCTAssertEqual(loadCount, 2, "geänderte mtime muss neu laden")
    }

    func testStoreFallsBackWhenFileMissingOrBroken() {
        let url = URL(fileURLWithPath: "/fake/models_cache.json")

        // Datei fehlt (kein Stat) → Fallback-Katalog.
        let missing = CodexModelCatalogStore(
            fileURL: url,
            dataLoader: { _ in XCTFail("darf ohne Stat nicht lesen"); return Data() },
            statLoader: { _ in nil }
        )
        XCTAssertEqual(missing.catalog(), .fallback)
        XCTAssertNil(missing.catalog().fetchedAt)

        // Datei kaputt → Fallback; nach Reparatur letzter guter Parse gecacht.
        var broken = true
        var stat: (mtime: Date, size: Int) = (Date(timeIntervalSince1970: 100), 10)
        let json = fixtureJSON(models: modelJSON(slug: "gpt-5.5", priority: 0))
        let store = CodexModelCatalogStore(
            fileURL: url,
            dataLoader: { _ in broken ? Data("müll".utf8) : json },
            statLoader: { _ in stat }
        )
        XCTAssertEqual(store.catalog(), .fallback)
        broken = false
        stat = (Date(timeIntervalSince1970: 200), 20)
        XCTAssertNotNil(store.catalog().fetchedAt, "repariert → echter Parse")
    }
}
