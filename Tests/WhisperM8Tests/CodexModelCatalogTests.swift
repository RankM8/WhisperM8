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

    func testUpgradeAndRetirementAreParsed() throws {
        let catalog = try XCTUnwrap(parse("""
        {
          "slug": "gpt-5.4-mini", "priority": 23, "visibility": "list",
          "upgrade": {"model": "gpt-5.6-luna", "retirement_at": "2026-08-31T19:00:00Z", "migration_markdown": "x"}
        },
        {"slug": "gpt-5.6-sol", "priority": 6, "visibility": "list", "upgrade": "kaputt"}
        """))
        let mini = try XCTUnwrap(catalog.model(slug: "gpt-5.4-mini"))
        XCTAssertEqual(mini.upgradeModel, "gpt-5.6-luna")
        XCTAssertTrue(mini.isRetired(at: ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z")!))
        XCTAssertFalse(mini.isRetired(at: ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z")!))
        let sol = try XCTUnwrap(catalog.model(slug: "gpt-5.6-sol"), "kaputtes upgrade-Objekt verwirft das Modell nicht")
        XCTAssertNil(sol.upgradeModel)
        XCTAssertFalse(sol.isRetired())
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
        // Priority-Sortierung über Merge-Grenzen hinweg: 5.5 (Cache: 0) vor
        // astra (Fallback: 1) vor sol (6) vor terra (7); 5.4 (16) dahinter.
        XCTAssertEqual(catalog.models.prefix(4).map(\.slug), ["gpt-5.5", "gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra"])
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

    func testFrontierPrefersHighestSlugVersionNotPriority() {
        // Ohne Fallback-Merge, damit der Tie-Break isoliert prüfbar bleibt
        // (der Fallback brächte gpt-6-astra mit).
        let catalog = CodexModelCatalog(
            models: ["gpt-5.5", "gpt-5.6-sol", "gpt-5.6-terra"].enumerated().map { index, slug in
                CodexCatalogModel(slug: slug, displayName: slug, detail: nil,
                                  defaultEffort: "medium",
                                  efforts: CodexModelCatalog.baselineEfforts, priority: index)
            },
            fetchedAt: nil
        )
        XCTAssertEqual(catalog.frontierModel?.slug, "gpt-5.6-sol", "höchste Version, Tie-Break kleinste priority")
    }

    func testFrontierPicksHypotheticalNewerVersionAutomatically() throws {
        let catalog = try XCTUnwrap(parse([
            modelJSON(slug: "gpt-5.6-sol", priority: 1),
            modelJSON(slug: "gpt-6.1-nova", priority: 9),
        ].joined(separator: ",")))
        // Der Fallback bringt gpt-6-astra (= 6.0) mit; ein 6.1 aus dem Cache
        // muss trotzdem automatisch gewinnen.
        XCTAssertEqual(catalog.frontierModel?.slug, "gpt-6.1-nova")
    }

    func testFrontierPrefersMajorOnlySlugOverHigherMinorOfOlderMajor() throws {
        // Reiner Cache-Fixture-Vergleich: 6.0 (Astra) schlägt 5.9.
        let catalog = try XCTUnwrap(parse([
            modelJSON(slug: "gpt-5.9-nova", priority: 0),
            modelJSON(slug: "gpt-6-astra", priority: 1),
        ].joined(separator: ",")))
        XCTAssertEqual(catalog.frontierModel?.slug, "gpt-6-astra")
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
        // Major-only-Slugs (GPT-6 Astra) zählen als <major>.0 — sonst bliebe
        // „auto" für immer auf der 5.6-Familie hängen.
        XCTAssertEqual(CodexModelCatalog.parseSlugVersion("gpt-6-astra")?.major, 6)
        XCTAssertEqual(CodexModelCatalog.parseSlugVersion("gpt-6-astra")?.minor, 0)
        XCTAssertEqual(CodexModelCatalog.parseSlugVersion("gpt-7")?.major, 7)
        XCTAssertNil(CodexModelCatalog.parseSlugVersion("gpt-4o"))
        XCTAssertNil(CodexModelCatalog.parseSlugVersion("gpt-6."))
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
        XCTAssertEqual(catalog.pickerModelSlugs(including: "gpt-6-astra").first, "gpt-6-astra")
        XCTAssertEqual(catalog.pickerModelSlugs(including: "gpt-5.5").filter { $0 == "gpt-5.5" }.count, 1)
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
            "gpt-6-astra"
        )
        XCTAssertEqual(
            CodexModelSelection.resolveSlug("gpt-5.4", catalog: .fallback),
            "gpt-5.4", "konkrete Slugs sind Pass-through"
        )
        XCTAssertEqual(
            CodexModelSelection.resolveSlug(" auto ", catalog: .fallback),
            "gpt-6-astra", "Whitespace tolerieren"
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
