import Foundation
import XCTest
@testable import WhisperM8

final class AgentProjectMetadataTests: XCTestCase {
    // MARK: - Project icon resolver

    func testProjectIconResolverPicksPublicFavicon() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let publicDir = projectURL.appendingPathComponent("public")
        try FileManager.default.createDirectory(at: publicDir, withIntermediateDirectories: true)
        let favicon = publicDir.appendingPathComponent("favicon.png")
        try Data([0x89]).write(to: favicon)

        let result = AgentProjectIconResolver.findIconRelativePath(in: projectURL.path)
        XCTAssertEqual(result, "public/favicon.png")
    }

    func testProjectIconResolverPrefersAppleTouchIconOverFavicon() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let publicDir = projectURL.appendingPathComponent("public")
        try FileManager.default.createDirectory(at: publicDir, withIntermediateDirectories: true)
        try Data([0x89]).write(to: publicDir.appendingPathComponent("favicon.ico"))
        try Data([0x89]).write(to: publicDir.appendingPathComponent("apple-touch-icon.png"))

        let result = AgentProjectIconResolver.findIconRelativePath(in: projectURL.path)
        XCTAssertEqual(result, "public/apple-touch-icon.png", "PNG mit hoher Auflösung muss vor .ico gewinnen")
    }

    func testProjectIconResolverFallsBackToRepoRoot() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        try Data([0x89]).write(to: projectURL.appendingPathComponent("logo.png"))

        let result = AgentProjectIconResolver.findIconRelativePath(in: projectURL.path)
        XCTAssertEqual(result, "logo.png")
    }

    func testProjectIconResolverReturnsNilForEmptyRepo() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }
        XCTAssertNil(AgentProjectIconResolver.findIconRelativePath(in: projectURL.path))
    }

    // MARK: - Project icon resolver · browser-like (manifest)

    /// Wie podomedica/360Web-Manager: das Manifest deklariert das Icon, der
    /// `src` (root-absolut `/…`) liegt neben dem Manifest. Wir lösen relativ
    /// zum Manifest-Ordner auf und nehmen das größte existierende Icon — auch
    /// wenn der Dateiname allein (brand-mark) kein Icon-Kandidat wäre.
    func testProjectIconResolverReadsWebManifestAndResolvesRelativeToManifest() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let publicDir = projectURL.appendingPathComponent("public")
        try FileManager.default.createDirectory(at: publicDir, withIntermediateDirectories: true)
        try Data([0x89]).write(to: publicDir.appendingPathComponent("brand-mark-192.png"))
        try Data([0x89]).write(to: publicDir.appendingPathComponent("brand-mark-512.png"))
        let manifest = """
        {"icons":[
          {"src":"/brand-mark-192.png","sizes":"192x192"},
          {"src":"/brand-mark-512.png","sizes":"512x512"}
        ]}
        """
        try manifest.data(using: .utf8)!.write(to: publicDir.appendingPathComponent("site.webmanifest"))

        let result = AgentProjectIconResolver.findIconRelativePath(in: projectURL.path)
        XCTAssertEqual(result, "public/brand-mark-512.png", "größtes deklariertes Icon, relativ zum Manifest-Ordner")
    }

    func testProjectIconResolverSkipsManifestIconsThatDoNotExist() throws {
        // customer-sites-Fall: Manifest verweist auf nicht existierende Icons,
        // sonst liegen nur dekorative Feature-SVGs herum → kein Icon.
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let favicons = projectURL.appendingPathComponent("public/img/favicons")
        try FileManager.default.createDirectory(at: favicons, withIntermediateDirectories: true)
        let manifest = #"{"icons":[{"src":"/android-icon-192x192.png","sizes":"192x192"}]}"#
        try manifest.data(using: .utf8)!.write(to: favicons.appendingPathComponent("manifest.json"))

        let features = projectURL.appendingPathComponent("public/img/features")
        try FileManager.default.createDirectory(at: features, withIntermediateDirectories: true)
        try Data([0x89]).write(to: features.appendingPathComponent("standort-icon.svg"))

        XCTAssertNil(AgentProjectIconResolver.findIconRelativePath(in: projectURL.path))
    }

    // MARK: - Project icon resolver · scored scan

    func testProjectIconResolverFindsNextAppRouterFavicon() throws {
        // headless-woo: Next.js App Router legt das Favicon in src/app/ ab.
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let appDir = projectURL.appendingPathComponent("src/app")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        try Data([0x89]).write(to: appDir.appendingPathComponent("favicon.ico"))

        XCTAssertEqual(AgentProjectIconResolver.findIconRelativePath(in: projectURL.path), "src/app/favicon.ico")
    }

    func testProjectIconResolverFindsNestedBrandFaviconJpg() throws {
        // heartbeat-bewertung: public/brand/favicon.jpg (verschachtelt + jpg).
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let brand = projectURL.appendingPathComponent("public/brand")
        try FileManager.default.createDirectory(at: brand, withIntermediateDirectories: true)
        try Data([0x89]).write(to: brand.appendingPathComponent("favicon.jpg"))

        XCTAssertEqual(AgentProjectIconResolver.findIconRelativePath(in: projectURL.path), "public/brand/favicon.jpg")
    }

    func testProjectIconResolverIgnoresDecorativeFeatureIcons() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let features = projectURL.appendingPathComponent("src/assets/img")
        try FileManager.default.createDirectory(at: features, withIntermediateDirectories: true)
        for name in ["google-review-icon.png", "marker-icon.png", "oeffnungszeiten-icon.svg"] {
            try Data([0x89]).write(to: features.appendingPathComponent(name))
        }
        XCTAssertNil(AgentProjectIconResolver.findIconRelativePath(in: projectURL.path))
    }

    func testProjectIconResolverPrunesNodeModules() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let nodeModules = projectURL.appendingPathComponent("node_modules/some-pkg")
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try Data([0x89]).write(to: nodeModules.appendingPathComponent("favicon.png"))

        XCTAssertNil(AgentProjectIconResolver.findIconRelativePath(in: projectURL.path), "Icons in node_modules zählen nicht")
    }

    // MARK: - Project icon resolver · scoring (pure)

    func testIconScoringRanksBrandNamesAboveDecorative() {
        let favicon = AgentProjectIconResolver.score(forImageRelativePath: "public/favicon.png")
        let appleTouch = AgentProjectIconResolver.score(forImageRelativePath: "public/apple-touch-icon.png")
        let faviconIco = AgentProjectIconResolver.score(forImageRelativePath: "public/favicon.ico")
        let decorative = AgentProjectIconResolver.score(forImageRelativePath: "public/img/features/standort-icon.svg")
        let randomPhoto = AgentProjectIconResolver.score(forImageRelativePath: "public/hero-photo.jpg")

        XCTAssertGreaterThanOrEqual(favicon, 80)
        XCTAssertGreaterThan(appleTouch, faviconIco, "PNG-Apple-Touch schlägt das .ico")
        XCTAssertLessThan(decorative, 80, "Feature-Icons sind keine Brand-Icons")
        XCTAssertEqual(decorative, 0)
        XCTAssertEqual(randomPhoto, 0, "Nicht-Icon-Namen sind keine Kandidaten")
    }

    func testIconScoringRejectsDeeplyNestedForeignAssets() {
        // ListM8-Fall: ein apple-touch-icon tief in docs/.../design-handoff/
        // ist NICHT das Projekt-Favicon → unter der Tiefen-Grenze.
        let deep = AgentProjectIconResolver.score(
            forImageRelativePath: "docs/REFACTORING/handoff/project/assets/apple-touch-icon.png"
        )
        XCTAssertEqual(deep, 0, "Tiefe > 3 → kein Kandidat")

        // Flache Variante derselben Datei bleibt ein starker Kandidat.
        let shallow = AgentProjectIconResolver.score(forImageRelativePath: "public/apple-touch-icon.png")
        XCTAssertGreaterThanOrEqual(shallow, 80)
    }

    func testIconScoringPrefersSourceOverBuildOutput() {
        let source = AgentProjectIconResolver.score(forImageRelativePath: "public/brand/favicon.jpg")
        let build = AgentProjectIconResolver.score(forImageRelativePath: "dist/brand/favicon.jpg")
        XCTAssertGreaterThan(source, build, "identisches Icon in public schlägt die dist-Kopie")
    }

    func testIconScoringRejectsHashedMarketingLogo() {
        // headless-woo-Fall: tiefes Marketing-Logo mit Hash-Suffix darf nicht
        // das echte Favicon verdrängen.
        let hashedLogo = AgentProjectIconResolver.score(
            forImageRelativePath: "public/images/brand/berlin/logo-colorful-qnqyfsnj8uxa13ldbvzhrhrf.png"
        )
        XCTAssertLessThan(hashedLogo, 80, "tiefer Hash-Logo-Pfad ist kein Brand-Favicon")
    }

    func testParseSizeHint() {
        XCTAssertEqual(AgentProjectIconResolver.parseSizeHint("favicon-512x512"), 512)
        XCTAssertEqual(AgentProjectIconResolver.parseSizeHint("icon-192"), 192)
        XCTAssertNil(AgentProjectIconResolver.parseSizeHint("favicon"))
        XCTAssertNil(AgentProjectIconResolver.parseSizeHint("apple-touch-icon"))
    }

    // MARK: - Project metadata persistence

    func testRenameProjectPersistsTrimmedName() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory(), name: "Old Name")
        try store.renameProject(id: project.id, name: "  New Name  ")
        let workspace = store.loadWorkspace()
        XCTAssertEqual(workspace.projects.first?.name, "New Name")
    }

    func testRenameProjectIgnoresEmptyName() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory(), name: "Stable Name")
        try store.renameProject(id: project.id, name: "   ")
        XCTAssertEqual(store.loadWorkspace().projects.first?.name, "Stable Name")
    }

    func testSetProjectColorPersists() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory(), name: "p")
        try store.setProjectColor(id: project.id, color: "#FF453A")
        XCTAssertEqual(store.loadWorkspace().projects.first?.color, "#FF453A")
    }

    func testApplyAutoResolvedProjectIconStoresPathAndAttemptedFlag() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory(), name: "p")
        try store.applyAutoResolvedProjectIcon(id: project.id, relativePath: "public/favicon.png")
        let updated = store.loadWorkspace().projects.first
        XCTAssertEqual(updated?.iconRelativePath, "public/favicon.png")
        XCTAssertEqual(updated?.iconAutoLookupAttempted, true)
    }

    func testApplyAutoResolvedWithNilStillMarksAttempted() throws {
        // Wenn kein Icon gefunden wurde, müssen wir trotzdem `attempted=true`
        // setzen, damit der nächste Reload nicht erneut scannt.
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory(), name: "p")
        try store.applyAutoResolvedProjectIcon(id: project.id, relativePath: nil)
        let updated = store.loadWorkspace().projects.first
        XCTAssertNil(updated?.iconRelativePath)
        XCTAssertEqual(updated?.iconAutoLookupAttempted, true)
    }

    func testClearProjectIconResetsBothSlotsAndAttemptedFlag() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory(), name: "p")
        try store.setProjectCustomIcon(id: project.id, absolutePath: "/tmp/x.png")
        try store.applyAutoResolvedProjectIcon(id: project.id, relativePath: "public/favicon.png")
        try store.clearProjectIcon(id: project.id)
        let updated = store.loadWorkspace().projects.first
        XCTAssertNil(updated?.iconRelativePath)
        XCTAssertNil(updated?.customIconAbsolutePath)
        XCTAssertNil(updated?.iconAutoLookupAttempted)
    }

    func testProjectResolvedIconURLPrefersCustomOverRelative() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }
        let custom = projectURL.appendingPathComponent("custom.png")
        try Data([0x89]).write(to: custom)
        try Data([0x89]).write(to: projectURL.appendingPathComponent("logo.png"))

        let project = AgentProject(
            name: "p",
            path: projectURL.path,
            iconRelativePath: "logo.png",
            customIconAbsolutePath: custom.path
        )
        XCTAssertEqual(project.resolvedIconURL?.lastPathComponent, "custom.png")
    }

    func testProjectResolvedIconURLFallsBackToRelativeWhenCustomMissing() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try Data([0x89]).write(to: projectURL.appendingPathComponent("logo.png"))

        let project = AgentProject(
            name: "p",
            path: projectURL.path,
            iconRelativePath: "logo.png",
            customIconAbsolutePath: "/nonexistent/path.png"
        )
        XCTAssertEqual(project.resolvedIconURL?.lastPathComponent, "logo.png")
    }
}
